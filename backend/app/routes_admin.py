import secrets
import string
from collections import defaultdict
from datetime import date, datetime, timedelta
from typing import Literal
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from pydantic import BaseModel, EmailStr, Field

from .common import (
    audit, clinic_today, db, mask_name, normalize_phone, one, rpc, settings, utc_iso, validate_password,
)
from .routes_doctor import AvailabilitySlot
from .security import require_roles

router = APIRouter(prefix="/api/v1/admin", tags=["admin"])
admin_only = require_roles("admin")

MANAGED_ROLES = ("doctor", "staff", "nurse")
USER_COLUMNS = ("id,full_name,email,phone,role,department_id,specialty,license_number,room,consultation_hours,is_active,"
                "must_change_password,last_login_at,created_at,"
                "department:hq_departments!hq_profiles_department_id_fkey(name),availability:hq_doctor_availability(*)")


class StaffAccountCreate(BaseModel):
    email: EmailStr
    full_name: str = Field(min_length=2, max_length=120)
    role: Literal["doctor", "staff", "nurse"]
    department_id: UUID
    specialty: str | None = Field(default=None, max_length=120)
    license_number: str | None = Field(default=None, max_length=120)
    room: str | None = Field(default=None, max_length=40)
    phone: str | None = Field(default=None, max_length=32)
    consultation_hours: str | None = Field(default=None, max_length=80)


class UserUpdate(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    department_id: UUID | None = None
    specialty: str | None = Field(default=None, max_length=120)
    license_number: str | None = Field(default=None, max_length=120)
    room: str | None = Field(default=None, max_length=40)
    is_active: bool | None = None
    model_config = {"extra": "forbid"}


class DepartmentCreate(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    code: str = Field(min_length=2, max_length=24, pattern=r"^[A-Za-z0-9_-]+$")
    description: str | None = Field(default=None, max_length=500)


class QueueRuleUpdate(BaseModel):
    slot_duration_minutes: int = Field(default=15, ge=5, le=240)
    max_patients_per_day: int = Field(default=40, ge=1, le=1000)
    allow_walk_ins: bool = True
    walk_in_policy: str = Field(default="after_booked", max_length=40)
    grace_minutes: int = Field(default=10, ge=1, le=120)
    late_after_minutes: int = Field(default=15, ge=1, le=240)


class AnnouncementCreate(BaseModel):
    title: str = Field(min_length=2, max_length=160)
    message: str = Field(min_length=2, max_length=4000)
    target_role: Literal["patient", "doctor", "staff", "nurse", "admin"] | None = None
    department_id: UUID | None = None


class BreakGlassReview(BaseModel):
    outcome: Literal["appropriate", "inappropriate"]
    note: str | None = Field(default=None, max_length=1000)


class PhotoUnlock(BaseModel):
    reason: str = Field(min_length=10, max_length=300)


def generate_temp_password() -> str:
    """16 chars, guaranteed to satisfy the strict staff password policy."""
    alphabet = string.ascii_letters + string.digits + "!@#$%^&*-_"
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(16))
        try:
            validate_password(pw, strict=True)
            return pw
        except HTTPException:
            continue


def fetch_all(query_factory, page: int = 1000, max_pages: int = 30) -> list[dict]:
    out: list[dict] = []
    for i in range(max_pages):
        rows = query_factory().range(i * page, (i + 1) * page - 1).execute().data
        out.extend(rows)
        if len(rows) < page:
            break
    return out


# ---------------------------------------------------------------- overview ----
@router.get("/overview")
def admin_overview(actor: dict = Depends(admin_only)):
    today = clinic_today().isoformat()
    appts = db().table("hq_appointments").select("id,status,priority").eq("appointment_date", today).execute().data
    profiles = db().table("hq_profiles").select("role").eq("is_active", True).execute().data
    counts: dict[str, int] = {}
    for a in appts:
        counts[a["status"]] = counts.get(a["status"], 0) + 1
    pending_review = len(db().table("hq_break_glass").select("id").is_("reviewed_at", "null").execute().data)
    since = (datetime.now(ZoneInfo("UTC")) - timedelta(hours=24)).isoformat()
    failed = len(db().table("hq_audit_log").select("id").eq("success", False).gte("at", since).execute().data)
    roles = defaultdict(int)
    for p in profiles:
        roles[p["role"]] += 1
    return {
        "appointments_today": len(appts), "waiting": counts.get("booked", 0) + counts.get("checked_in", 0),
        "completed": counts.get("completed", 0), "emergencies_today": sum(1 for a in appts if a["priority"] == "emergency"),
        "patients": roles["patient"], "doctors": roles["doctor"], "staff": roles["staff"], "nurses": roles["nurse"],
        "departments": departments_list(), "status_counts": counts,
        "break_glass_pending_review": pending_review, "failed_security_events_24h": failed,
    }


def departments_list() -> list[dict]:
    return db().table("hq_departments").select("*").eq("is_active", True).order("name").execute().data


# ------------------------------------------------------------------- users ----
@router.get("/users")
def admin_users(role: Literal["doctor", "staff", "nurse"] | None = None, actor: dict = Depends(admin_only)):
    query = db().table("hq_profiles").select(USER_COLUMNS).in_("role", list(MANAGED_ROLES))
    if role:
        query = query.eq("role", role)
    return query.order("full_name").execute().data


@router.post("/users", status_code=status.HTTP_201_CREATED)
def admin_create_user(payload: StaffAccountCreate, request: Request, actor: dict = Depends(admin_only)):
    """The ONLY way to create a doctor, staff or nurse account. Returns a one-time temporary password."""
    if not db().table("hq_departments").select("id").eq("id", str(payload.department_id)).eq("is_active", True).limit(1).execute().data:
        raise HTTPException(status_code=404, detail="Department not found or inactive.")
    if db().table("hq_profiles").select("id").ilike("email", str(payload.email)).limit(1).execute().data:
        raise HTTPException(status_code=409, detail="An account with this email already exists.")
    temp_password = generate_temp_password()
    try:
        created = db().auth.admin.create_user({
            "email": str(payload.email), "password": temp_password, "email_confirm": True,
            "user_metadata": {"full_name": payload.full_name}}).user
    except Exception as exc:
        raise HTTPException(status_code=409, detail="Could not create the account. The email may already be registered.") from exc
    if created is None:
        raise HTTPException(status_code=500, detail="Supabase Auth did not return the new account.")
    profile = {
        "id": str(created.id), "full_name": " ".join(payload.full_name.split()), "email": str(payload.email),
        "phone": normalize_phone(payload.phone), "role": payload.role, "department_id": str(payload.department_id),
        "specialty": payload.specialty, "license_number": payload.license_number, "room": payload.room,
        "consultation_hours": payload.consultation_hours, "signup_finalized": True, "signup_nonce": None,
        "approval_status": "approved", "is_active": True, "must_change_password": True,
    }
    try:
        row = db().table("hq_profiles").upsert(profile, on_conflict="id").execute().data[0]
    except Exception as exc:
        db().auth.admin.delete_user(str(created.id))
        raise HTTPException(status_code=500, detail="The profile could not be saved. Nothing was created.") from exc
    audit(actor, "admin.user_created", target_type="profile", target_id=row["id"], details={"role": payload.role}, request=request)
    return {"user": row, "temporary_password": temp_password,
            "note": "Share this password privately. It is shown once and must be changed at first sign-in."}


def _managed_user(user_id: UUID) -> dict:
    user = one("hq_profiles", user_id)
    if user["role"] not in MANAGED_ROLES:
        raise HTTPException(status_code=403, detail="Only doctor, staff and nurse accounts can be managed here.")
    return user


@router.patch("/users/{user_id}")
def admin_update_user(user_id: UUID, payload: UserUpdate, request: Request, actor: dict = Depends(admin_only)):
    current = _managed_user(user_id)
    changes = payload.model_dump(exclude_unset=True, mode="json")
    if not changes:
        return current
    if changes.get("phone"):
        changes["phone"] = normalize_phone(changes["phone"])
    changes["updated_at"] = utc_iso()
    row = db().table("hq_profiles").update(changes).eq("id", str(user_id)).execute().data[0]
    if "is_active" in changes:
        try:  # a deactivated account can no longer refresh its session either
            db().auth.admin.update_user_by_id(str(user_id), {"ban_duration": "none" if changes["is_active"] else "876000h"})
        except Exception:
            pass
    audit(actor, "admin.user_updated", target_type="profile", target_id=str(user_id), details={k: v for k, v in changes.items() if k != "updated_at"}, request=request)
    return row


@router.post("/users/{user_id}/reset-password")
def admin_reset_password(user_id: UUID, request: Request, actor: dict = Depends(admin_only)):
    _managed_user(user_id)
    temp_password = generate_temp_password()
    try:
        db().auth.admin.update_user_by_id(str(user_id), {"password": temp_password})
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The password could not be reset.") from exc
    db().table("hq_profiles").update({"must_change_password": True}).eq("id", str(user_id)).execute()
    audit(actor, "admin.password_reset", target_type="profile", target_id=str(user_id), request=request)
    return {"temporary_password": temp_password, "note": "Share this password privately. It must be changed at next sign-in."}


@router.put("/users/{user_id}/availability")
def admin_update_availability(user_id: UUID, slots: list[AvailabilitySlot], actor: dict = Depends(admin_only)):
    doctor = one("hq_profiles", user_id)
    if doctor.get("role") != "doctor":
        raise HTTPException(status_code=403, detail="Availability can only be assigned to doctor accounts.")
    db().table("hq_doctor_availability").delete().eq("doctor_id", str(user_id)).execute()
    rows = [{**slot.model_dump(mode="json"), "doctor_id": str(user_id)} for slot in slots]
    if rows:
        db().table("hq_doctor_availability").insert(rows).execute()
        first = rows[0]
        db().table("hq_profiles").update({"consultation_hours": f"{first['start_time'][:5]}–{first['end_time'][:5]}"}).eq("id", str(user_id)).execute()
    return {"availability": rows}


# ------------------------------------------------------------- departments ----
@router.get("/departments")
def admin_departments(actor: dict = Depends(admin_only)):
    deps = db().table("hq_departments").select("*,rules:hq_queue_rules(*)").order("name").execute().data
    today = clinic_today().isoformat()
    doctors = db().table("hq_profiles").select("department_id").eq("role", "doctor").eq("is_active", True).execute().data
    active = db().table("hq_appointments").select("department_id").eq("appointment_date", today).in_("status", ["booked", "checked_in", "called", "in_progress"]).execute().data
    for d in deps:
        d["doctor_count"] = sum(1 for x in doctors if x["department_id"] == d["id"])
        d["waiting"] = sum(1 for x in active if x["department_id"] == d["id"])
    return deps


@router.post("/departments", status_code=status.HTTP_201_CREATED)
def admin_add_department(payload: DepartmentCreate, request: Request, actor: dict = Depends(admin_only)):
    row = db().table("hq_departments").insert({"name": payload.name.strip(), "code": payload.code.upper(), "description": payload.description}).execute().data[0]
    audit(actor, "admin.department_created", target_type="department", target_id=row["id"], request=request)
    return row


@router.patch("/departments/{department_id}")
def admin_update_department(department_id: UUID, payload: DepartmentCreate, request: Request, actor: dict = Depends(admin_only)):
    rows = db().table("hq_departments").update({"name": payload.name.strip(), "code": payload.code.upper(), "description": payload.description}).eq("id", str(department_id)).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Department not found.")
    audit(actor, "admin.department_updated", target_type="department", target_id=str(department_id), request=request)
    return rows[0]


@router.delete("/departments/{department_id}")
def admin_disable_department(department_id: UUID, request: Request, actor: dict = Depends(admin_only)):
    if db().table("hq_profiles").select("id").eq("department_id", str(department_id)).eq("role", "doctor").eq("is_active", True).limit(1).execute().data:
        raise HTTPException(status_code=409, detail="Move or deactivate this department's doctors first.")
    rows = db().table("hq_departments").update({"is_active": False}).eq("id", str(department_id)).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Department not found.")
    audit(actor, "admin.department_disabled", target_type="department", target_id=str(department_id), request=request)
    return rows[0]


@router.put("/departments/{department_id}/queue-rules")
def admin_queue_rules(department_id: UUID, payload: QueueRuleUpdate, request: Request, actor: dict = Depends(admin_only)):
    one("hq_departments", department_id, "id")
    record = {**payload.model_dump(), "department_id": str(department_id), "updated_by": actor["id"], "updated_at": utc_iso()}
    row = db().table("hq_queue_rules").upsert(record, on_conflict="department_id").execute().data[0]
    audit(actor, "admin.queue_rules_updated", target_type="department", target_id=str(department_id), details=payload.model_dump(), request=request)
    return row


# ----------------------------------------------------------- announcements ----
@router.post("/announcements", status_code=status.HTTP_201_CREATED)
def admin_announce(payload: AnnouncementCreate, request: Request, actor: dict = Depends(admin_only)):
    record = {"title": payload.title, "message": payload.message, "target_role": payload.target_role,
              "department_id": str(payload.department_id) if payload.department_id else None, "published_by": actor["id"]}
    announcement = db().table("hq_announcements").insert(record).execute().data[0]
    query = db().table("hq_profiles").select("id").eq("is_active", True)
    if payload.target_role:
        query = query.eq("role", payload.target_role)
    if payload.department_id:
        query = query.eq("department_id", str(payload.department_id))
    recipients = query.execute().data
    if recipients:
        db().table("hq_notifications").insert([
            {"recipient_id": u["id"], "title": payload.title, "message": payload.message, "category": "info"} for u in recipients]).execute()
    audit(actor, "admin.announcement_sent", target_type="announcement", target_id=announcement["id"], details={"recipients": len(recipients)}, request=request)
    return {"announcement": announcement, "notified": len(recipients)}


@router.get("/announcements")
def admin_announcements(actor: dict = Depends(admin_only)):
    return db().table("hq_announcements").select("*").order("published_at", desc=True).limit(100).execute().data


# ---------------------------------------------------------- security centre ----
@router.get("/audit")
def audit_log(
    limit: int = Query(default=50, ge=1, le=200), before_id: int | None = None,
    action: str | None = Query(default=None, max_length=60), only_failures: bool = False,
    actor: dict = Depends(admin_only),
):
    query = db().table("hq_audit_log").select("*").order("id", desc=True).limit(limit)
    if before_id:
        query = query.lt("id", before_id)
    if action:
        query = query.like("action", action.replace("%", "") + "%")
    if only_failures:
        query = query.eq("success", False)
    return query.execute().data


@router.get("/break-glass")
def break_glass_list(actor: dict = Depends(admin_only)):
    rows = (db().table("hq_break_glass").select(
        "*,doctor:hq_profiles!hq_break_glass_doctor_id_fkey(full_name,specialty),"
        "patient:hq_profiles!hq_break_glass_patient_id_fkey(full_name)")
        .order("opened_at", desc=True).limit(100).execute().data)
    for row in rows:
        row["patient_label"] = mask_name((row.pop("patient") or {}).get("full_name", ""))
    return sorted(rows, key=lambda r: r["reviewed_at"] is not None)


@router.post("/break-glass/{session_id}/review")
def break_glass_review(session_id: UUID, payload: BreakGlassReview, request: Request, actor: dict = Depends(admin_only)):
    session = one("hq_break_glass", session_id)
    if session["reviewed_at"]:
        raise HTTPException(status_code=409, detail="This access was already reviewed.")
    if session["doctor_id"] == actor["id"]:
        raise HTTPException(status_code=403, detail="You cannot review your own access.")
    if payload.outcome == "inappropriate" and len((payload.note or "").strip()) < 5:
        raise HTTPException(status_code=422, detail="Add a note explaining why this access was inappropriate.")
    row = db().table("hq_break_glass").update({
        "reviewed_by": actor["id"], "reviewed_at": utc_iso(), "review_outcome": payload.outcome,
        "review_note": payload.note, "closed_at": session["closed_at"] or utc_iso()}).eq("id", str(session_id)).execute().data[0]
    audit(actor, "break_glass.reviewed", target_type="break_glass", target_id=str(session_id), patient_id=session["patient_id"], details={"outcome": payload.outcome}, request=request)
    return row


@router.get("/identity-photos")
def photo_list(actor: dict = Depends(admin_only)):
    rows = (db().table("hq_identity_photos").select(
        "id,status,locked,confirmed_at,created_at,patient:hq_profiles!hq_identity_photos_patient_id_fkey(full_name)")
        .eq("locked", True).order("confirmed_at", desc=True).limit(50).execute().data)
    return [{"id": r["id"], "status": r["status"], "confirmed_at": r["confirmed_at"],
             "label": mask_name((r.get("patient") or {}).get("full_name") or "Walk-in patient")} for r in rows]


@router.post("/identity-photos/{photo_id}/unlock")
def photo_unlock(photo_id: UUID, payload: PhotoUnlock, request: Request, actor: dict = Depends(admin_only)):
    photo = rpc("hq_unlock_identity_photo", {"p_photo_id": str(photo_id), "p_admin_id": actor["id"], "p_reason": payload.reason})
    return {"id": photo["id"], "status": photo["status"], "locked": photo["locked"]}


# ---------------------------------------------------------------- analytics ----
@router.get("/analytics")
def analytics(days: int = Query(default=30, ge=7, le=180), actor: dict = Depends(admin_only)):
    """De-identified: no patient names, ids or contact details leave this endpoint."""
    start = (clinic_today() - timedelta(days=days)).isoformat()
    rows = fetch_all(lambda: db().table("hq_appointments").select(
        "doctor_id,status,appointment_date,checked_in_at,called_at,started_at,completed_at,priority,source,is_late")
        .gte("appointment_date", start).order("appointment_date"))
    zone = ZoneInfo(settings.clinic_timezone)

    def parse(v):
        return datetime.fromisoformat(v) if v else None

    waits, consults = [], []
    by_hour = [0] * 24
    by_weekday = [0] * 7
    daily: dict[str, dict] = defaultdict(lambda: {"total": 0, "completed": 0})
    per_doc: dict[str, dict] = defaultdict(lambda: {"completed": 0, "no_show": 0, "consults": [], "waits": []})
    priority_mix = defaultdict(int)
    for r in rows:
        if r["status"] == "cancelled":
            continue
        d = date.fromisoformat(r["appointment_date"])
        by_weekday[d.weekday()] += 1
        daily[r["appointment_date"]]["total"] += 1
        priority_mix[r["priority"]] += 1
        stats = per_doc[r["doctor_id"]]
        ci, called, started, done = parse(r["checked_in_at"]), parse(r["called_at"]), parse(r["started_at"]), parse(r["completed_at"])
        if ci:
            by_hour[ci.astimezone(zone).hour] += 1
        if ci and called and 0 <= (called - ci).total_seconds() <= 8 * 3600:
            waits.append((called - ci).total_seconds() / 60)
            stats["waits"].append(waits[-1])
        if r["status"] == "completed":
            daily[r["appointment_date"]]["completed"] += 1
            stats["completed"] += 1
            begin = started or called
            if begin and done and 0 < (done - begin).total_seconds() <= 4 * 3600:
                consults.append((done - begin).total_seconds() / 60)
                stats["consults"].append(consults[-1])
        elif r["status"] == "no_show":
            stats["no_show"] += 1
    completed = sum(s["completed"] for s in per_doc.values())
    no_show = sum(s["no_show"] for s in per_doc.values())
    names = {p["id"]: p["full_name"] for p in db().table("hq_profiles").select("id,full_name").eq("role", "doctor").execute().data}
    avg = lambda xs: round(sum(xs) / len(xs), 1) if xs else None  # noqa: E731
    return {
        "days": days, "total_visits": sum(d["total"] for d in daily.values()), "completed": completed, "no_show": no_show,
        "no_show_rate": round(no_show / (completed + no_show) * 100, 1) if completed + no_show else 0.0,
        "avg_wait_minutes": avg(waits), "avg_consult_minutes": avg(consults),
        "by_hour": by_hour, "by_weekday": by_weekday, "priority_mix": dict(priority_mix),
        "walk_in_share": round(sum(1 for r in rows if r["source"] == "walk_in") / len(rows) * 100, 1) if rows else 0.0,
        "late_arrivals": sum(1 for r in rows if r["is_late"]),
        "daily": [{"date": k, **v} for k, v in sorted(daily.items())][-14:],
        "doctor_load": sorted(({"doctor": "Dr. " + names.get(k, "Unknown"), "completed": v["completed"], "no_show": v["no_show"],
                                "avg_consult": avg(v["consults"]), "avg_wait": avg(v["waits"])} for k, v in per_doc.items()),
                              key=lambda x: -x["completed"])[:12],
    }
