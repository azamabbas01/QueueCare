from datetime import date
from uuid import uuid4

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, Response
from fastapi.security import HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, Field
from uuid import UUID

from . import gotrue
from .common import (
    audit, auth_rate_limiter, clinic_today, client_ip, db, first, hash_national_id, normalize_national_id,
    normalize_phone, require_doctor, settings, utc_iso, validate_password,
)
from .database import get_auth_client
from .security import (
    admin_any_aal, bearer, current_actor, current_actor_basic, public_profile,
)
from .sms import flush_sms_outbox

app = FastAPI(
    title="QueueCare API", version="2.0.0",
    description="Hospital appointments and queue management API",
    docs_url=None if settings.is_production else "/docs",
    redoc_url=None if settings.is_production else "/redoc",
    openapi_url=None if settings.is_production else "/openapi.json",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_origin_regex=None if settings.is_production else r"https?://(localhost|127\.0\.0\.1)(:\d+)?",
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    allow_headers=["Authorization", "Content-Type"],
)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    response.headers.setdefault("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
    if request.url.path.startswith("/api/"):
        response.headers["Cache-Control"] = "no-store"
    if settings.is_production:
        response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    return response


AUTH_LIMITS = {
    "login": ((60, 60), (10, 900)),
    "register": ((10, 3600), (3, 3600)),
    "resend-signup-confirmation": ((10, 900), (3, 900)),
    "forgot-password": ((10, 900), (3, 900)),
    "refresh": ((120, 60), (60, 60)),
}
MAX_FAILED_LOGINS = 5
LOCKOUT_SECONDS = 900
SIGNUP_RESPONSE = {
    "email_confirmation_required": True,
    "message": "If this email can be registered, a confirmation link has been sent.",
}


def enforce_auth_limits(request: Request, action: str, email: str) -> None:
    ip = client_ip(request) or "unknown"
    per_ip, per_email = AUTH_LIMITS[action]
    for key, (limit, window) in ((f"{action}:ip:{ip}", per_ip), (f"{action}:email:{email.strip().casefold()}", per_email)):
        allowed, retry_after = auth_rate_limiter.consume(key, limit=limit, window_seconds=window)
        if not allowed:
            raise HTTPException(status_code=429, detail="Too many requests. Please wait before trying again.",
                                headers={"Retry-After": str(retry_after)})


class LoginCredentials(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class RegisterPatient(BaseModel):
    """Self-service registration. There is deliberately NO role field: only patients can sign up."""
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    full_name: str = Field(min_length=2, max_length=120)
    phone: str = Field(min_length=7, max_length=32)
    national_id: str | None = Field(default=None, max_length=32)
    dob: date | None = None
    preferred_language: str = Field(default="en", pattern="^(en|ur)$")
    accept_terms: bool
    consent_data_use: bool
    consent_photo: bool = False

    model_config = {"extra": "forbid"}  # a client that sends "role" is rejected outright


class SignupEmail(BaseModel):
    email: EmailStr


class CompleteSignupRequest(BaseModel):
    token_hash: str | None = Field(default=None, min_length=20, max_length=512)


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=10, max_length=2048)


class ChangePassword(BaseModel):
    current_password: str = Field(min_length=1, max_length=128)
    new_password: str = Field(min_length=8, max_length=128)


class MfaVerify(BaseModel):
    factor_id: str = Field(min_length=10, max_length=64)
    code: str = Field(pattern=r"^\d{6}$")


class ProfileUpdateSelf(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    preferred_language: str | None = Field(default=None, pattern="^(en|ur)$")
    sms_opt_in: bool | None = None
    model_config = {"extra": "forbid"}


@app.get("/health")
def health():
    return {"status": "ok", "service": "QueueCare API"}


# ----------------------------------------------------------- email confirm ----
def finalize_verified_signup(access_token: str) -> dict:
    try:
        verified_user = get_auth_client().auth.get_user(access_token).user
    except Exception as exc:
        raise HTTPException(status_code=401, detail="The confirmation link is invalid or expired.") from exc
    if verified_user is None:
        raise HTTPException(status_code=401, detail="The confirmation link is invalid or expired.")
    if not (getattr(verified_user, "email_confirmed_at", None) or getattr(verified_user, "confirmed_at", None)):
        raise HTTPException(status_code=403, detail="Confirm this email address before completing signup.")

    rows = db().table("hq_profiles").select("*").eq("id", str(verified_user.id)).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=403, detail="The signup profile could not be found.")
    profile = rows[0]
    if profile.get("signup_finalized", True):
        return profile
    nonce = profile.get("signup_nonce")
    if not nonce:
        raise HTTPException(status_code=403, detail="This signup request cannot be completed.")
    try:
        # Always produces a PATIENT. Role metadata from the client is ignored by the database function.
        finalized = db().rpc("hq_finalize_patient_signup", {
            "p_user_id": str(verified_user.id), "p_full_name": profile.get("full_name", ""),
            "p_email": str(verified_user.email or profile.get("email", "")),
            "p_signup_nonce": nonce, "p_phone": profile.get("phone"),
        }).execute().data
    except Exception as exc:
        raise HTTPException(status_code=409, detail="Could not finish signup. Please register again.") from exc
    profile = first(finalized)
    if not profile:
        raise HTTPException(status_code=503, detail="Signup could not be finalized. Please contact support.")

    consents = profile.get("signup_consents") or {}
    rows = [{"patient_id": profile["id"], "kind": kind, "granted": bool(consents.get(kind)),
             "recorded_by": profile["id"]} for kind in ("terms", "data_use", "photo") if kind in consents]
    if rows:
        db().table("hq_consents").insert(rows).execute()
    audit(profile, "auth.signup_completed", target_type="profile", target_id=profile["id"], required=False)
    return profile


@app.get("/auth/confirm", response_class=HTMLResponse)
def email_confirmation_page():
    response = HTMLResponse("""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer"><title>Confirm QueueCare account</title>
<style>body{font:16px system-ui,sans-serif;background:#f2f7ff;color:#0b2252;margin:0;min-height:100vh;display:grid;place-items:center}.card{background:white;border-radius:20px;padding:36px;max-width:480px;margin:20px;box-shadow:0 12px 40px #002f8418}h1{color:#002f84;font-size:24px}p{line-height:1.6;color:#526780}</style>
</head><body><main class="card"><h1>Confirming your QueueCare account</h1><p id="message">Please wait while we securely finish signup.</p></main><script src="/auth/confirm.js" defer></script></body></html>""")
    response.headers["Content-Security-Policy"] = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    response.headers["Cache-Control"] = "no-store"
    return response


@app.get("/auth/confirm.js")
def email_confirmation_script():
    script = """(async()=>{const message=document.getElementById('message');const query=new URLSearchParams(location.search);const fragment=new URLSearchParams(location.hash.slice(1));const tokenHash=fragment.get('token_hash')||query.get('token_hash');const token=fragment.get('access_token');const type=fragment.get('type')||query.get('type');const error=fragment.get('error_description')||fragment.get('error')||query.get('error_description')||query.get('error');history.replaceState(null,document.title,location.pathname);if(error||(!tokenHash&&!token)||(type&&type!=='signup'&&type!=='email')){message.textContent=error?'This confirmation link is invalid or expired. Request a new email from QueueCare.':'This link cannot confirm a QueueCare signup.';return}try{const headers={Accept:'application/json'};const options={method:'POST',headers};if(tokenHash){headers['Content-Type']='application/json';options.body=JSON.stringify({token_hash:tokenHash})}else{headers.Authorization='Bearer '+token}const response=await fetch('/api/v1/auth/complete-signup',options);const result=await response.json();if(!response.ok)throw new Error(typeof result.detail==='string'?result.detail:'Signup could not be completed.');message.textContent='Your email is confirmed. Opening QueueCare sign in…';const link=document.createElement('a');link.href='queuecare://auth/signin';link.textContent='Open QueueCare';link.style='display:inline-block;margin-top:16px;padding:12px 18px;background:#002f84;color:white;border-radius:10px;text-decoration:none;font-weight:700';document.querySelector('.card').appendChild(link);setTimeout(()=>{location.href=link.href},500)}catch(e){message.textContent=e.message||'Signup could not be completed. Request a new confirmation email.'}})();"""
    return Response(script, media_type="application/javascript", headers={
        "Content-Security-Policy": "default-src 'none'; script-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'",
        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"})


@app.post("/api/v1/auth/complete-signup")
def complete_signup_from_confirmation(
    payload: CompleteSignupRequest | None = None,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
):
    access_token = credentials.credentials if credentials else None
    if payload and payload.token_hash:
        try:
            verification = get_auth_client().auth.verify_otp({"token_hash": payload.token_hash, "type": "email"})
        except Exception as exc:
            raise HTTPException(status_code=401, detail="The confirmation link is invalid or expired.") from exc
        if verification.user is None or verification.session is None:
            raise HTTPException(status_code=401, detail="The confirmation link is invalid or expired.")
        access_token = verification.session.access_token
    if not access_token:
        raise HTTPException(status_code=401, detail="The confirmation link is invalid or expired.")
    profile = finalize_verified_signup(access_token)
    return {"verified": True, "role": profile.get("role")}


# ---------------------------------------------------------------- register ----
@app.post("/api/v1/auth/register")
def register_patient(payload: RegisterPatient, request: Request):
    """Patients only. Doctor, staff, nurse and admin accounts are created by an administrator."""
    enforce_auth_limits(request, "register", str(payload.email))
    if not (payload.accept_terms and payload.consent_data_use):
        raise HTTPException(status_code=422, detail="You must accept the terms and agree to the use of your health data to register.")
    validate_password(payload.password, email=str(payload.email))
    phone = normalize_phone(payload.phone)
    national_id = normalize_national_id(payload.national_id)
    name = " ".join(payload.full_name.split())

    existing = db().table("hq_profiles").select("id").ilike("email", str(payload.email)).limit(1).execute().data
    if existing:
        return SIGNUP_RESPONSE  # indistinguishable from a new signup: no email enumeration

    # Duplicate-record detection: same national ID, or same phone AND same name.
    id_hash = hash_national_id(national_id) if national_id else None
    if id_hash and db().table("hq_profiles").select("id").eq("national_id_hash", id_hash).limit(1).execute().data:
        raise HTTPException(status_code=409, detail="A patient account already exists for this ID. Sign in, or ask reception for help.")
    same_phone = db().table("hq_profiles").select("full_name").eq("role", "patient").eq("phone", phone).execute().data
    if any(r["full_name"].casefold() == name.casefold() for r in same_phone):
        raise HTTPException(status_code=409, detail="An account already exists for this name and phone number. Sign in, or ask reception for help.")

    nonce = str(uuid4())
    try:
        auth_result = get_auth_client().auth.sign_up({
            "email": payload.email, "password": payload.password,
            "options": {"data": {"full_name": name, "signup_nonce": nonce},
                        "email_redirect_to": settings.auth_confirmation_url},
        })
    except Exception as exc:
        raise HTTPException(status_code=400, detail="Could not create account. Check the email and password.") from exc
    user = auth_result.user
    if user is None:
        raise HTTPException(status_code=400, detail="Account registration did not return a user.")

    def rollback():
        try:
            db().auth.admin.delete_user(str(user.id))
        except Exception:
            pass

    if auth_result.session is not None:
        rollback()
        raise HTTPException(status_code=503, detail="Email confirmation is disabled in Supabase. Enable it to require confirmation links.")
    try:
        staged = (db().table("hq_profiles").update({
            "phone": phone, "national_id_hash": id_hash,
            "national_id_last4": national_id[-4:] if national_id else None,
            "dob": payload.dob.isoformat() if payload.dob else None,
            "preferred_language": payload.preferred_language,
            "signup_consents": {"terms": True, "data_use": True, "photo": payload.consent_photo},
        }).eq("id", str(user.id)).eq("signup_nonce", nonce).eq("signup_finalized", False).execute().data)
    except Exception as exc:
        rollback()
        raise HTTPException(status_code=503, detail="Could not prepare signup confirmation. Please try again.") from exc
    if not staged:
        rollback()
        raise HTTPException(status_code=503, detail="Could not prepare signup confirmation. Please try again.")
    return SIGNUP_RESPONSE


@app.post("/api/v1/auth/resend-signup-confirmation")
def resend_signup_confirmation(payload: SignupEmail, request: Request):
    enforce_auth_limits(request, "resend-signup-confirmation", str(payload.email))
    try:
        get_auth_client().auth.resend({"type": "signup", "email": str(payload.email),
                                       "options": {"email_redirect_to": settings.auth_confirmation_url}})
    except Exception:
        pass
    return {"message": "If signup is awaiting confirmation, a new confirmation email has been sent."}


# ------------------------------------------------------------------- login ----
def session_payload(session, profile: dict, **extra) -> dict:
    return {
        "access_token": session.access_token, "refresh_token": session.refresh_token,
        "token_type": getattr(session, "token_type", "bearer"), "expires_in": session.expires_in,
        "user": public_profile(profile), **extra,
    }


@app.post("/api/v1/auth/login")
def login(payload: LoginCredentials, request: Request):
    email = str(payload.email)
    enforce_auth_limits(request, "login", email)
    fail_key = f"loginfail:{email.strip().casefold()}"
    wait = auth_rate_limiter.blocked(fail_key, limit=MAX_FAILED_LOGINS, window_seconds=LOCKOUT_SECONDS)
    if wait:
        raise HTTPException(status_code=429, detail="Too many failed attempts. Try again later.",
                            headers={"Retry-After": str(wait)})
    try:
        result = get_auth_client().auth.sign_in_with_password({"email": email, "password": payload.password})
    except Exception as exc:
        auth_rate_limiter.consume(fail_key, limit=MAX_FAILED_LOGINS, window_seconds=LOCKOUT_SECONDS)
        audit(None, "auth.login_failed", details={"email": email.lower()}, request=request, success=False, required=False)
        raise HTTPException(status_code=401, detail="Email or password is incorrect.") from exc
    if result.user is None or result.session is None:
        raise HTTPException(status_code=401, detail="Sign-in did not return an active session.")

    rows = db().table("hq_profiles").select("*").eq("id", str(result.user.id)).limit(1).execute().data
    if not rows or not rows[0].get("is_active", False):
        audit(None, "auth.login_blocked", target_id=str(result.user.id), request=request, success=False, required=False)
        raise HTTPException(status_code=403, detail="This account is not active. Contact the hospital administrator.")
    profile = rows[0]
    if not profile.get("signup_finalized", True):
        raise HTTPException(status_code=403, detail="Confirm your email address before signing in.")
    auth_rate_limiter.reset(fail_key)
    db().table("hq_profiles").update({"last_login_at": utc_iso()}).eq("id", profile["id"]).execute()
    audit(profile, "auth.login", target_type="profile", target_id=profile["id"], request=request, required=False)

    extra: dict = {"must_change_password": bool(profile.get("must_change_password"))}
    if profile["role"] == "admin":
        # Admin tokens are aal1 until TOTP is verified; the API refuses them for everything but MFA.
        factors = [f for f in gotrue.list_factors(result.session.access_token)
                   if f.get("factor_type", f.get("type")) == "totp" and f.get("status") == "verified"]
        window_open = bool(profile.get("mfa_enroll_until")) and profile["mfa_enroll_until"] > utc_iso()
        extra["mfa"] = ({"mode": "verify", "factor_id": factors[0]["id"]} if factors else
                        {"mode": "enroll" if window_open else "blocked"})
    return session_payload(result.session, profile, **extra)


@app.post("/api/v1/auth/refresh")
def refresh_session(payload: RefreshRequest, request: Request):
    enforce_auth_limits(request, "refresh", client_ip(request) or "unknown")
    try:
        result = get_auth_client().auth.refresh_session(payload.refresh_token)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Your session has expired. Sign in again.") from exc
    if result.session is None or result.user is None:
        raise HTTPException(status_code=401, detail="Your session has expired. Sign in again.")
    rows = db().table("hq_profiles").select("*").eq("id", str(result.user.id)).limit(1).execute().data
    if not rows or not rows[0].get("is_active"):
        raise HTTPException(status_code=403, detail="This account is not active.")
    return session_payload(result.session, rows[0], must_change_password=bool(rows[0].get("must_change_password")))


@app.post("/api/v1/auth/logout")
def logout(request: Request, actor: dict = Depends(current_actor_basic)):
    try:
        db().auth.admin.sign_out(actor["_token"])
    except Exception:
        pass
    audit(actor, "auth.logout", request=request, required=False)
    return {"signed_out": True}


@app.post("/api/v1/auth/forgot-password")
def forgot_password(payload: SignupEmail, request: Request):
    enforce_auth_limits(request, "forgot-password", str(payload.email))
    try:
        get_auth_client().auth.reset_password_email(str(payload.email))
    except Exception:
        pass
    return {"message": "If the account exists, a reset email has been sent."}


@app.get("/api/v1/auth/me")
def me(actor: dict = Depends(current_actor_basic)):
    return {"user": public_profile(actor), "must_change_password": bool(actor.get("must_change_password")),
            "mfa_verified": actor["role"] != "admin" or actor.get("_aal") == "aal2"}


@app.post("/api/v1/auth/change-password")
def change_password(payload: ChangePassword, request: Request, actor: dict = Depends(current_actor_basic)):
    if actor["role"] == "admin" and actor.get("_aal") != "aal2":
        raise HTTPException(status_code=403, detail={"code": "mfa_required", "message": "Verify your authenticator code first."})
    key = f"pwchange:{actor['id']}"
    if auth_rate_limiter.blocked(key, limit=5, window_seconds=900):
        raise HTTPException(status_code=429, detail="Too many attempts. Try again later.")
    try:
        get_auth_client().auth.sign_in_with_password({"email": actor["email"], "password": payload.current_password})
    except Exception as exc:
        auth_rate_limiter.consume(key, limit=5, window_seconds=900)
        audit(actor, "auth.password_change_failed", request=request, success=False, required=False)
        raise HTTPException(status_code=401, detail="Your current password is incorrect.") from exc
    if payload.new_password == payload.current_password:
        raise HTTPException(status_code=422, detail="Choose a password you have not used before.")
    validate_password(payload.new_password, strict=actor["role"] != "patient", email=actor.get("email"))
    try:
        db().auth.admin.update_user_by_id(actor["id"], {"password": payload.new_password})
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The password could not be changed. Try again.") from exc
    db().table("hq_profiles").update({"must_change_password": False}).eq("id", actor["id"]).execute()
    audit(actor, "auth.password_changed", target_type="profile", target_id=actor["id"], request=request)
    return {"changed": True}


# ------------------------------------------------------------- admin MFA ----
@app.post("/api/v1/auth/mfa/enroll")
def mfa_enroll(request: Request, actor: dict = Depends(admin_any_aal)):
    """Start TOTP enrolment. Allowed only inside the window opened by scripts/create_admin.py,
    so someone who merely knows an admin's password cannot attach their own authenticator."""
    if actor.get("_aal") == "aal2":
        raise HTTPException(status_code=409, detail="This account is already protected by an authenticator.")
    token = actor["_token"]
    factors = [f for f in gotrue.list_factors(token) if f.get("factor_type", f.get("type")) == "totp"]
    if any(f.get("status") == "verified" for f in factors):
        raise HTTPException(status_code=409, detail="An authenticator is already registered. Enter your code instead.")
    if not actor.get("mfa_enroll_until") or actor["mfa_enroll_until"] <= utc_iso():
        raise HTTPException(status_code=403, detail="Authenticator setup is closed for this account. Ask the system owner to reopen it.")
    for factor in factors:
        gotrue.delete_factor(token, factor["id"])
    created = gotrue.enroll_totp(token, f"QueueCare admin {uuid4().hex[:6]}")
    totp = created.get("totp") or {}
    audit(actor, "auth.mfa_enroll_started", request=request)
    return {"factor_id": created["id"], "secret": totp.get("secret"), "uri": totp.get("uri")}


@app.post("/api/v1/auth/mfa/verify")
def mfa_verify(payload: MfaVerify, request: Request, actor: dict = Depends(admin_any_aal)):
    key = f"mfa:{actor['id']}"
    wait = auth_rate_limiter.blocked(key, limit=5, window_seconds=300)
    if wait:
        raise HTTPException(status_code=429, detail="Too many wrong codes. Wait a few minutes.", headers={"Retry-After": str(wait)})
    try:
        session = gotrue.verify_totp(actor["_token"], payload.factor_id, payload.code)
    except HTTPException:
        auth_rate_limiter.consume(key, limit=5, window_seconds=300)
        audit(actor, "auth.mfa_failed", request=request, success=False, required=False)
        raise
    auth_rate_limiter.reset(key)
    db().table("hq_profiles").update({"mfa_enroll_until": None}).eq("id", actor["id"]).execute()
    audit(actor, "auth.mfa_verified", request=request, required=False)
    return {
        "access_token": session["access_token"], "refresh_token": session["refresh_token"],
        "token_type": session.get("token_type", "bearer"), "expires_in": session.get("expires_in", 3600),
        "user": public_profile(actor), "must_change_password": bool(actor.get("must_change_password")),
    }


# --------------------------------------------------------------- directory ----
PUBLIC_DOCTOR_DIRECTORY_COLUMNS = (
    "id,full_name,department_id,specialty,room,consultation_hours,is_active,"
    "department:hq_departments!hq_profiles_department_id_fkey(name)"
)


@app.get("/api/v1/departments")
def departments():
    return db().table("hq_departments").select("*").eq("is_active", True).order("name").execute().data


@app.get("/api/v1/doctors")
def doctors(department_id: UUID | None = None, specialty: str | None = None):
    query = db().table("hq_profiles").select(PUBLIC_DOCTOR_DIRECTORY_COLUMNS).eq("role", "doctor").eq("is_active", True)
    if department_id:
        query = query.eq("department_id", str(department_id))
    if specialty:
        query = query.ilike("specialty", f"%{specialty[:60]}%")
    records = query.order("full_name").execute().data
    today = clinic_today().isoformat()
    appointments = db().table("hq_appointments").select("doctor_id").eq("appointment_date", today).in_("status", ["booked", "checked_in", "called", "in_progress"]).execute().data
    feedback = db().table("hq_feedback").select("rating,appointment:hq_appointments!inner(doctor_id)").execute().data
    waiting: dict[str, int] = {}
    ratings: dict[str, list[int]] = {}
    for item in appointments:
        waiting[item["doctor_id"]] = waiting.get(item["doctor_id"], 0) + 1
    for item in feedback:
        key = (item.get("appointment") or {}).get("doctor_id")
        if key:
            ratings.setdefault(key, []).append(int(item["rating"]))
    for doctor in records:
        values = ratings.get(doctor["id"], [])
        doctor["waiting_count"] = waiting.get(doctor["id"], 0)
        doctor["rating"] = round(sum(values) / len(values), 1) if values else None
    return records


@app.get("/api/v1/doctors/{doctor_id}/availability")
def doctor_availability(doctor_id: UUID, day: int | None = Query(default=None, ge=0, le=6)):
    require_doctor(doctor_id)
    query = db().table("hq_doctor_availability").select("*").eq("doctor_id", str(doctor_id)).order("weekday").order("start_time")
    if day is not None:
        query = query.eq("weekday", day)
    return {"availability": query.execute().data}


@app.get("/api/v1/doctors/{doctor_id}/slots")
def doctor_slots(doctor_id: UUID, day: date):
    """Free time slots for a date, so patients pick a real slot instead of being given the first one."""
    doctor = require_doctor(doctor_id)
    if day < clinic_today():
        return {"slots": []}
    rules = db().table("hq_queue_rules").select("slot_duration_minutes").eq("department_id", doctor["department_id"]).limit(1).execute().data
    minutes = rules[0]["slot_duration_minutes"] if rules else 15
    weekday = day.weekday()
    windows = [w for w in db().table("hq_doctor_availability").select("start_time,end_time,is_break")
               .eq("doctor_id", str(doctor_id)).eq("weekday", weekday).execute().data]
    work = [w for w in windows if not w["is_break"]]
    breaks = [w for w in windows if w["is_break"]]
    taken = {r["start_time"][:5] for r in db().table("hq_appointments").select("start_time")
             .eq("doctor_id", str(doctor_id)).eq("appointment_date", day.isoformat())
             .in_("status", ["booked", "checked_in", "called", "in_progress", "skipped"]).execute().data}
    from datetime import datetime, timedelta
    from .common import clinic_now
    now_local = clinic_now().replace(tzinfo=None)
    out = []
    for w in work:
        cursor = datetime.combine(day, datetime.strptime(w["start_time"][:5], "%H:%M").time())
        end = datetime.combine(day, datetime.strptime(w["end_time"][:5], "%H:%M").time())
        while cursor + timedelta(minutes=minutes) <= end:
            label = cursor.strftime("%H:%M")
            in_break = any(datetime.combine(day, datetime.strptime(b["start_time"][:5], "%H:%M").time()) <= cursor <
                           datetime.combine(day, datetime.strptime(b["end_time"][:5], "%H:%M").time()) for b in breaks)
            if label not in taken and not in_break and cursor > now_local:
                out.append(label)
            cursor += timedelta(minutes=minutes)
    return {"slots": sorted(set(out)), "slot_minutes": minutes}


# ----------------------------------------------------- notifications/profile ----
@app.get("/api/v1/notifications")
def notifications(actor: dict = Depends(current_actor)):
    return db().table("hq_notifications").select("*").eq("recipient_id", actor["id"]).order("created_at", desc=True).limit(100).execute().data


@app.post("/api/v1/notifications/read-all")
def mark_notifications_read(actor: dict = Depends(current_actor)):
    rows = db().table("hq_notifications").update({"is_read": True}).eq("recipient_id", actor["id"]).eq("is_read", False).execute().data
    return {"updated": len(rows)}


@app.put("/api/v1/profile")
def update_profile(payload: ProfileUpdateSelf, actor: dict = Depends(current_actor)):
    changes = payload.model_dump(exclude_unset=True)
    if not changes:
        raise HTTPException(status_code=422, detail="Nothing to update.")
    if changes.get("phone"):
        changes["phone"] = normalize_phone(changes["phone"])
    if "full_name" in changes:
        changes["full_name"] = " ".join(changes["full_name"].split())
    changes["updated_at"] = utc_iso()
    return public_profile(db().table("hq_profiles").update(changes).eq("id", actor["id"]).execute().data[0])


@app.post("/api/v1/internal/flush-sms", include_in_schema=False)
def flush_sms(background: BackgroundTasks, actor: dict = Depends(current_actor)):
    if actor["role"] != "admin":
        raise HTTPException(status_code=403, detail="Not allowed.")
    background.add_task(flush_sms_outbox)
    return {"queued": True}


from . import routes_admin, routes_doctor, routes_patient, routes_staff  # noqa: E402

for _module in (routes_patient, routes_doctor, routes_staff, routes_admin):
    app.include_router(_module.router)
