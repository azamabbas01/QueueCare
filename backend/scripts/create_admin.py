#!/usr/bin/env python3
"""Create (or recover) a QueueCare administrator. Run on a trusted machine that has the service key.

    python scripts/create_admin.py --email owner@hospital.org --name "Full Name"
    python scripts/create_admin.py --email owner@hospital.org --reopen-mfa     # lost authenticator

Administrators can never be created through the app or the public API. This script is the
only supported path, so a stolen app session cannot mint new administrators.

After running it, sign in to the QueueCare app within 24 hours: you will be asked to scan a QR
code with an authenticator app (Google Authenticator, Microsoft Authenticator, Aegis, 1Password...).
"""

import argparse
import getpass
import os
import sys
from datetime import datetime, timedelta, timezone

import httpx

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.common import db, settings, validate_password  # noqa: E402
from fastapi import HTTPException  # noqa: E402


def admin_headers() -> dict:
    key = settings.supabase_service_role_key
    headers = {"apikey": key, "Content-Type": "application/json"}

    # New Supabase secret keys are API keys, not JWTs. Send them only as "apikey".
    if not key.startswith("sb_secret_"):
        headers["Authorization"] = f"Bearer {key}"

    return headers


def auth_url(path: str) -> str:
    return settings.supabase_url.rstrip("/") + "/auth/v1" + path


def open_enrollment_window(user_id: str) -> None:
    until = (datetime.now(timezone.utc) + timedelta(hours=24)).isoformat()
    db().table("hq_profiles").update({"mfa_enroll_until": until}).eq("id", user_id).execute()


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--email", required=True)
    parser.add_argument("--name", help="Full name (required when creating)")
    parser.add_argument(
        "--reopen-mfa",
        action="store_true",
        help="Remove the existing authenticator and reopen set-up",
    )
    args = parser.parse_args()
    email = args.email.strip().lower()

    existing = (
        db()
        .table("hq_profiles")
        .select("id,role")
        .ilike("email", email)
        .limit(1)
        .execute()
        .data
    )

    if args.reopen_mfa:
        if not existing or existing[0]["role"] != "admin":
            print("No administrator with that email.")
            return 1

        uid = existing[0]["id"]
        factors = httpx.get(
            auth_url(f"/admin/users/{uid}/factors"),
            headers=admin_headers(),
            timeout=10,
        ).json()

        for factor in factors if isinstance(factors, list) else []:
            httpx.delete(
                auth_url(f"/admin/users/{uid}/factors/{factor['id']}"),
                headers=admin_headers(),
                timeout=10,
            )

        open_enrollment_window(uid)
        db().table("hq_audit_log").insert(
            {
                "actor_role": "system",
                "action": "admin.mfa_reopened",
                "target_id": uid,
                "details": {"via": "cli"},
            }
        ).execute()
        print("Authenticator removed. Sign in within 24 hours to set up a new one.")
        return 0

    if existing:
        print("An account with that email already exists.")
        return 1

    if not args.name or len(args.name.strip()) < 2:
        print("--name is required.")
        return 1

    password = getpass.getpass("Password (12+ characters, upper/lower/number/symbol): ")
    if password != getpass.getpass("Repeat password: "):
        print("Passwords do not match.")
        return 1

    try:
        validate_password(password, strict=True, email=email)
    except HTTPException as exc:
        print(exc.detail)
        return 1

    created = db().auth.admin.create_user(
        {
            "email": email,
            "password": password,
            "email_confirm": True,
            "user_metadata": {"full_name": args.name.strip()},
        }
    ).user

    profile = {
        "id": str(created.id),
        "full_name": args.name.strip(),
        "email": email,
        "role": "admin",
        "approval_status": "approved",
        "is_active": True,
        "signup_finalized": True,
        "signup_nonce": None,
        "must_change_password": False,
    }
    db().table("hq_profiles").upsert(profile, on_conflict="id").execute()
    open_enrollment_window(str(created.id))
    db().table("hq_audit_log").insert(
        {
            "actor_role": "system",
            "action": "admin.created",
            "target_id": str(created.id),
            "details": {"via": "cli"},
        }
    ).execute()

    print(f"Administrator created: {email}")
    print(
        "Next: open the QueueCare app and sign in within 24 hours "
        "to set up your authenticator app."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())