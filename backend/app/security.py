from collections.abc import Callable

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .database import get_auth_client, get_service_client
from .gotrue import token_aal

bearer = HTTPBearer(auto_error=False)

# Roles that only an administrator can create. Nobody can self-register into them.
PRIVILEGED_ROLES = ("doctor", "staff", "nurse", "admin")

# Columns that must never leave the server in an API response.
PRIVATE_PROFILE_FIELDS = {
    "signup_nonce", "signup_requested_role", "signup_consents", "national_id_hash",
    "approval_status", "signup_finalized",
}


def public_profile(profile: dict) -> dict:
    return {k: v for k, v in profile.items() if k not in PRIVATE_PROFILE_FIELDS and not k.startswith("_")}


def authenticate(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> dict:
    """Verify the bearer token with Supabase Auth and load the active profile."""
    if credentials is None:
        raise HTTPException(status_code=401, detail="Sign in to continue.")
    token = credentials.credentials
    try:
        user = get_auth_client().auth.get_user(token).user
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Your session is invalid or expired.") from exc
    if user is None:
        raise HTTPException(status_code=401, detail="Your session is invalid or expired.")

    rows = (
        get_service_client().table("hq_profiles").select("*")
        .eq("id", str(user.id)).limit(1).execute().data
    )
    if not rows or not rows[0].get("is_active", False) or not rows[0].get("signup_finalized", True):
        raise HTTPException(status_code=403, detail="This account is not active.")
    profile = dict(rows[0])
    profile["_aal"] = token_aal(token)
    profile["_token"] = token
    return profile


def current_actor_basic(actor: dict = Depends(authenticate)) -> dict:
    """Signed in, but possibly still owing a password change or MFA step."""
    return actor


def current_actor(actor: dict = Depends(current_actor_basic)) -> dict:
    """Fully authorised caller.

    * A password issued by an administrator must be changed before anything else works.
    * Administrators must also have completed TOTP multi-factor verification (aal2).
    """
    if actor.get("must_change_password"):
        raise HTTPException(status_code=403, detail={
            "code": "password_change_required", "message": "Choose a new password to continue."})
    if actor["role"] == "admin" and actor.get("_aal") != "aal2":
        raise HTTPException(status_code=403, detail={
            "code": "mfa_required", "message": "Verify your authenticator code to continue."})
    return actor


def require_roles(*roles: str) -> Callable:
    def dependency(actor: dict = Depends(current_actor)) -> dict:
        if actor["role"] not in roles:
            raise HTTPException(status_code=403, detail="Your account cannot perform this action.")
        return actor

    return dependency


def admin_any_aal(actor: dict = Depends(current_actor_basic)) -> dict:
    """Admin who has passed the password step; used only by the MFA endpoints."""
    if actor["role"] != "admin":
        raise HTTPException(status_code=403, detail="Your account cannot perform this action.")
    return actor
