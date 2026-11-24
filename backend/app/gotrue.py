"""Thin client for Supabase Auth (GoTrue) MFA endpoints.

The Supabase Python client keeps the session in the client object, which does not
fit a stateless API, so the three MFA calls are made directly with the caller's
access token. Admin accounts must finish TOTP verification (aal2) before the API
accepts any admin request.
"""
import base64
import json

import httpx
from fastapi import HTTPException

from .config import get_settings


def _headers(access_token: str) -> dict:
    return {
        "apikey": get_settings().supabase_publishable_key,
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
    }


def _url(path: str) -> str:
    return get_settings().supabase_url.rstrip("/") + "/auth/v1" + path


def _call(method: str, path: str, access_token: str, body: dict | None = None) -> dict:
    try:
        response = httpx.request(method, _url(path), headers=_headers(access_token), json=body, timeout=10)
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=503, detail="Authentication service is unreachable.") from exc
    if response.status_code >= 400:
        raise HTTPException(status_code=400, detail="The verification code is not valid. Try again.")
    return response.json() if response.content else {}


def token_aal(access_token: str) -> str:
    """Read the authenticator assurance level claim (call only after the token was verified)."""
    try:
        payload = access_token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return str(json.loads(base64.urlsafe_b64decode(payload)).get("aal", "aal1"))
    except Exception:
        return "aal1"


def list_factors(access_token: str) -> list[dict]:
    user = _call("GET", "/user", access_token)
    return user.get("factors") or []


def enroll_totp(access_token: str, friendly_name: str) -> dict:
    return _call("POST", "/factors", access_token, {
        "factor_type": "totp", "friendly_name": friendly_name, "issuer": "QueueCare",
    })


def delete_factor(access_token: str, factor_id: str) -> None:
    _call("DELETE", f"/factors/{factor_id}", access_token)


def verify_totp(access_token: str, factor_id: str, code: str) -> dict:
    challenge = _call("POST", f"/factors/{factor_id}/challenge", access_token, {})
    return _call("POST", f"/factors/{factor_id}/verify", access_token, {
        "challenge_id": challenge["id"], "code": code,
    })
