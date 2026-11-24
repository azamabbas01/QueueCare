"""Helpers shared by the API modules."""
import hashlib
import hmac
import logging
import re
import warnings
from datetime import date, datetime, time, timedelta, timezone
from io import BytesIO
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import HTTPException, Request
from PIL import Image, ImageOps, UnidentifiedImageError
from postgrest.exceptions import APIError

from .config import get_settings
from .database import get_service_client
from .rate_limit import FixedWindowRateLimiter

log = logging.getLogger("queuecare")
settings = get_settings()
auth_rate_limiter = FixedWindowRateLimiter()

MEDICAL_RECORDS_BUCKET = "medical-records"
IDENTITY_BUCKET = "identity-photos"
MEDICAL_IMAGE_MAX_BYTES = 12 * 1024 * 1024
MEDICAL_IMAGE_MAX_PIXELS = 40_000_000
ACTIVE_STATUSES = ["booked", "checked_in", "called", "in_progress", "skipped"]
WAITING_STATUSES = ["checked_in"]


def clinic_now() -> datetime:
    return datetime.now(ZoneInfo(settings.clinic_timezone))


def clinic_today() -> date:
    return clinic_now().date()


def utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def db():
    return get_service_client()


def one(table: str, row_id: UUID | str, columns: str = "*") -> dict:
    rows = db().table(table).select(columns).eq("id", str(row_id)).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Record not found.")
    return rows[0]


def first(data):
    return data[0] if isinstance(data, list) and data else (None if isinstance(data, list) else data)


def rpc(name: str, params: dict):
    """Call a Postgres function; business-rule errors (QC00x) become clean 409 responses."""
    try:
        return first(db().rpc(name, params).execute().data)
    except APIError as exc:
        if str(getattr(exc, "code", "")).startswith("QC"):
            raise HTTPException(status_code=409, detail=getattr(exc, "message", "Request rejected.")) from exc
        log.exception("RPC %s failed", name)
        raise HTTPException(status_code=500, detail="The request could not be completed.") from exc


def client_ip(request: Request | None) -> str | None:
    return request.client.host if request is not None and request.client else None


# ------------------------------------------------------------------ audit ----
def audit(actor: dict | None, action: str, *, target_type: str | None = None, target_id: str | None = None,
          patient_id: str | None = None, details: dict | None = None, request: Request | None = None,
          success: bool = True, required: bool = True) -> None:
    """Append to the audit log.

    ``required=True`` (the default) fails closed: if the entry cannot be written the
    caller's request is refused, so clinical data is never read without a record.
    """
    row = {
        "actor_id": actor.get("id") if actor else None,
        "actor_role": actor.get("role") if actor else None,
        "actor_name": actor.get("full_name") if actor else None,
        "action": action, "target_type": target_type,
        "target_id": str(target_id) if target_id else None,
        "patient_id": str(patient_id) if patient_id else None,
        "details": details or {}, "ip": client_ip(request), "success": success,
    }
    try:
        db().table("hq_audit_log").insert(row).execute()
    except Exception as exc:
        log.exception("audit write failed for %s", action)
        if required:
            raise HTTPException(status_code=503, detail="The audit log is unavailable, so this action was refused.") from exc


# ---------------------------------------------------------- notifications ----
def queue_sms(recipient_id: str, body: str) -> bool:
    rows = db().table("hq_profiles").select("phone,sms_opt_in").eq("id", recipient_id).limit(1).execute().data
    if not rows or not rows[0].get("phone") or not rows[0].get("sms_opt_in", True):
        return False
    db().table("hq_sms_outbox").insert({"recipient_id": recipient_id, "phone": rows[0]["phone"], "body": body[:320]}).execute()
    return True


def notify(recipient_id: str, title: str, message: str, category: str = "info", sms: bool = False) -> None:
    db().table("hq_notifications").insert({
        "recipient_id": recipient_id, "title": title, "message": message, "category": category,
    }).execute()
    if sms:
        try:
            queue_sms(recipient_id, f"QueueCare: {title}. {message}")
        except Exception:
            log.exception("could not queue SMS")


def add_event(appointment_id: str, actor_id: str, event_type: str, details: dict | None = None) -> None:
    db().table("hq_queue_events").insert({
        "appointment_id": appointment_id, "actor_id": actor_id, "event_type": event_type, "details": details or {},
    }).execute()


# ------------------------------------------------------------ validation ----
def normalize_phone(raw: str | None) -> str | None:
    """Normalise to +<country><number> so duplicate detection compares like with like."""
    if raw is None or not str(raw).strip():
        return None
    text = str(raw).strip()
    digits = re.sub(r"\D", "", text)
    cc = settings.default_country_code
    if text.startswith("+"):
        result = digits
    elif digits.startswith("00"):
        result = digits[2:]
    elif digits.startswith("0"):
        result = cc + digits[1:]
    elif digits.startswith(cc) and len(digits) >= len(cc) + 9:
        result = digits
    else:
        result = cc + digits
    if not 9 <= len(result) <= 15:
        raise HTTPException(status_code=422, detail="Enter a valid phone number, for example 0300 1234567.")
    return "+" + result


def normalize_national_id(raw: str | None) -> str | None:
    if raw is None or not str(raw).strip():
        return None
    value = re.sub(r"[\s-]", "", str(raw)).upper()
    if not re.fullmatch(r"[A-Z0-9]{6,20}", value):
        raise HTTPException(status_code=422, detail="Enter a valid national ID number.")
    return value


def hash_national_id(value: str) -> str:
    return hmac.new(settings.national_id_pepper.encode(), value.encode(), hashlib.sha256).hexdigest()


def mask_name(name: str) -> str:
    parts = [p for p in name.split() if p]
    return " ".join(p[0] + "*" * max(1, len(p) - 1) if i else p for i, p in enumerate(parts)) or "—"


_COMMON_PASSWORDS = {"password", "password1", "12345678", "123456789", "qwerty123", "iloveyou", "admin123",
                     "welcome1", "letmein123", "queuecare", "queuecare1", "hospital1", "abc12345"}


def validate_password(password: str, *, strict: bool = False, email: str | None = None) -> None:
    """Patients: 8+ chars with a letter and a digit. Staff/admin accounts (strict): 12+ with mixed case and a symbol."""
    minimum = 12 if strict else 8
    problems = []
    if len(password) < minimum:
        problems.append(f"at least {minimum} characters")
    if not re.search(r"[A-Za-z]", password) or not re.search(r"\d", password):
        problems.append("letters and numbers")
    if strict and (not re.search(r"[a-z]", password) or not re.search(r"[A-Z]", password)
                   or not re.search(r"[^A-Za-z0-9]", password)):
        problems.append("upper and lower case letters and a symbol")
    if password.casefold() in _COMMON_PASSWORDS or (email and email.split("@")[0].casefold() in password.casefold()
                                                    and len(email.split("@")[0]) >= 4):
        problems.append("nothing easy to guess (not common words or your email)")
    if problems:
        raise HTTPException(status_code=422, detail="Password needs " + ", ".join(problems) + ".")


# ----------------------------------------------------------------- images ----
def compress_medical_image(raw: bytes, *, max_side: int = 2400) -> bytes:
    """Validate and normalise an uploaded image to a metadata-free JPEG."""
    if not raw or len(raw) > MEDICAL_IMAGE_MAX_BYTES:
        raise HTTPException(status_code=413, detail="Choose an image smaller than 12 MB.")
    Image.MAX_IMAGE_PIXELS = MEDICAL_IMAGE_MAX_PIXELS
    warnings.simplefilter("error", Image.DecompressionBombWarning)
    try:
        with Image.open(BytesIO(raw)) as source:
            if source.format not in {"JPEG", "PNG", "WEBP"}:
                raise HTTPException(status_code=415, detail="Use a JPG, PNG, or WEBP image.")
            source.verify()
        with Image.open(BytesIO(raw)) as source:
            image = ImageOps.exif_transpose(source).convert("RGB")
            image.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
            for quality in (88, 80, 72, 64):
                output = BytesIO()
                image.save(output, format="JPEG", quality=quality, optimize=True, progressive=True)
                if len(output.getvalue()) <= MEDICAL_IMAGE_MAX_BYTES:
                    return output.getvalue()
            raise HTTPException(status_code=413, detail="This image is still too large after compression.")
    except HTTPException:
        raise
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise HTTPException(status_code=415, detail="This image is invalid or too large to process.") from exc


def medical_record_metadata(record: dict) -> dict:
    return {key: record.get(key) for key in (
        "id", "patient_id", "appointment_id", "record_type", "title",
        "original_filename", "content_type", "file_size_bytes", "created_at")}


# ---------------------------------------------------------------- doctors ----
def require_doctor(doctor_id: UUID | str) -> dict:
    rows = (db().table("hq_profiles").select("id,full_name,department_id,is_active,role")
            .eq("id", str(doctor_id)).eq("role", "doctor").eq("is_active", True).limit(1).execute().data)
    if not rows:
        raise HTTPException(status_code=404, detail="Doctor not found or inactive.")
    return rows[0]


def ensure_doctor_not_on_leave(doctor_id: UUID, day: date, start_time: time) -> None:
    doctor = require_doctor(doctor_id)
    rules = db().table("hq_queue_rules").select("slot_duration_minutes").eq("department_id", doctor["department_id"]).limit(1).execute().data
    duration = rules[0]["slot_duration_minutes"] if rules else 15
    start = datetime.combine(day, start_time, tzinfo=ZoneInfo(settings.clinic_timezone))
    end = start + timedelta(minutes=duration)
    conflicts = (db().table("hq_doctor_time_off").select("id").eq("doctor_id", str(doctor_id))
                 .lt("starts_at", end.isoformat()).gt("ends_at", start.isoformat()).limit(1).execute().data)
    if conflicts:
        raise HTTPException(status_code=409, detail="The doctor is unavailable during the selected time.")


# ------------------------------------------------------------ queue maths ----
def queue_key(row: dict) -> tuple:
    rank = {"emergency": 0, "urgent": 1}.get(row.get("priority"), 2)
    return rank, row.get("queue_sort") or row.get("queue_number") or 0, row.get("queue_number") or 0


def average_consult_minutes(doctor_id: str, department_id: str | None = None) -> float:
    """Mean of the doctor's real recent consultation lengths; falls back to the slot length."""
    rows = (db().table("hq_appointments").select("started_at,called_at,completed_at")
            .eq("doctor_id", doctor_id).eq("status", "completed").not_.is_("completed_at", "null")
            .order("completed_at", desc=True).limit(30).execute().data)
    minutes = []
    for row in rows:
        begin = row.get("started_at") or row.get("called_at")
        if begin and row.get("completed_at"):
            delta = (datetime.fromisoformat(row["completed_at"]) - datetime.fromisoformat(begin)).total_seconds() / 60
            if 1 <= delta <= 120:
                minutes.append(delta)
    if len(minutes) >= 3:
        return round(sum(minutes) / len(minutes), 1)
    if department_id:
        rules = db().table("hq_queue_rules").select("slot_duration_minutes").eq("department_id", department_id).limit(1).execute().data
        if rules:
            return float(rules[0]["slot_duration_minutes"])
    return 10.0


def send_queue_alerts(doctor_id: str, day: date) -> None:
    """Tell waiting patients when 3 people, then 1 person, are ahead of them (push-style in-app plus SMS)."""
    rows = (db().table("hq_appointments").select("id,patient_id,queue_number,queue_sort,priority,status")
            .eq("doctor_id", doctor_id).eq("appointment_date", day.isoformat()).eq("status", "checked_in").execute().data)
    waiting = sorted(rows, key=queue_key)
    targets = {(r["id"], 3 if i == 3 else 1): r for i, r in enumerate(waiting) if i in (1, 3) and r.get("patient_id")}
    if not targets:
        return
    ids = list({t[0] for t in targets})
    sent = {(a["appointment_id"], a["threshold"]) for a in
            db().table("hq_queue_alerts").select("appointment_id,threshold").in_("appointment_id", ids).execute().data}
    for (appt_id, threshold), row in targets.items():
        if (appt_id, threshold) in sent:
            continue
        db().table("hq_queue_alerts").insert({"appointment_id": appt_id, "threshold": threshold}).execute()
        if threshold == 3:
            notify(row["patient_id"], "3 patients before you", f"Token A-{row['queue_number']}: please stay close to the waiting area.", "info", sms=True)
        else:
            notify(row["patient_id"], "You are almost next", f"Token A-{row['queue_number']}: only 1 patient is ahead of you.", "warning", sms=True)
