from datetime import date, datetime, time
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Query, Request, UploadFile, status
from fastapi.responses import Response
from pydantic import BaseModel, Field

from .common import (
    MEDICAL_IMAGE_MAX_BYTES, add_event, audit, clinic_now, clinic_today, db, ensure_doctor_not_on_leave, hash_national_id,
    mask_name, normalize_national_id, normalize_phone, notify, one, queue_key, require_doctor, rpc, utc_iso,
)
from .photos import confirm_photo, get_photo, has_consent, photo_bytes, photo_summary, store_photo
from .security import require_roles
from .sms import post_queue_change

router = APIRouter(prefix="/api/v1", tags=["staff"])
staff_only = require_roles("staff")
nurse_only = require_roles("nurse")
staff_or_nurse = require_roles("staff", "nurse")

LIST_SELECT = ("id,source,patient_name,patient_id,doctor_id,department_id,appointment_date,start_time,queue_number,queue_sort,"
               "status,priority,priority_reason,triage_status,is_late,recall_count,checked_in_at,"
               "patient:hq_profiles!hq_appointments_patient_id_fkey(full_name),"
               "doctor:hq_profiles!hq_appointments_doctor_id_fkey(full_name,room),department:hq_departments(name)")


class WalkInCreate(BaseModel):
    doctor_id: UUID
    patient_name: str = Field(min_length=2, max_length=120)
    patient_phone: str = Field(min_length=5, max_length=32)
    national_id: str | None = Field(default=None, max_length=32)
    appointment_date: date = Field(default_factory=clinic_today)
    start_time: time = Field(default_factory=lambda: clinic_now().time().replace(second=0, microsecond=0, tzinfo=None))
    notes: str | None = Field(default=None, max_length=1000)
    priority: Literal["emergency", "urgent", "routine"] = "routine"
    priority_reason: str | None = Field(default=None, max_length=200)
    link_patient_id: UUID | None = None
    confirm_new: bool = False
    consent_data: bool = False
    consent_photo: bool = False


class CheckInCode(BaseModel):
    code: UUID


class AppointmentReschedule(BaseModel):
    doctor_id: UUID
    appointment_date: date
    start_time: time


class PriorityChange(BaseModel):
    priority: Literal["emergency", "urgent", "routine"]
    reason: str | None = Field(default=None, max_length=200)


class PhotoConfirm(BaseModel):
    id_document_checked: bool


class TriageSave(BaseModel):
    temp_c: float | None = Field(default=None, ge=30, le=45)
    pulse: int | None = Field(default=None, ge=20, le=260)
    bp_systolic: int | None = Field(default=None, ge=40, le=280)
    bp_diastolic: int | None = Field(default=None, ge=20, le=200)
    spo2: int | None = Field(default=None, ge=40, le=100)
    resp_rate: int | None = Field(default=None, ge=4, le=80)
    weight_kg: float | None = Field(default=None, ge=0.5, le=400)
    height_cm: float | None = Field(default=None, ge=20, le=260)
    pain_score: int | None = Field(default=None, ge=0, le=10)
    chief_complaint: str | None = Field(default=None, max_length=500)
    notes: str | None = Field(default=None, max_length=1000)
    priority: Literal["emergency", "urgent", "routine"] = "routine"
    priority_reason: str | None = Field(default=None, max_length=200)


def _scoped(appointment_id: UUID, actor: dict, columns: str = "*") -> dict:
    appt = one("hq_appointments", appointment_id, columns if "department_id" in columns or columns == "*" else columns + ",department_id")
    if actor.get("department_id") and appt["department_id"] != actor["department_id"]:
        raise HTTPException(status_code=403, detail="This appointment is outside your department.")
    return appt


# ------------------------------------------------------------- staff queue ----
@router.get("/staff/queue")
def staff_queue(day: date = Query(default_factory=clinic_today), actor: dict = Depends(staff_only)):
    query = (db().table("hq_appointments").select(LIST_SELECT).eq("appointment_date", day.isoformat())
             .in_("status", ["booked", "checked_in", "called", "in_progress", "skipped"]))
    if actor.get("department_id"):
        query = query.eq("department_id", actor["department_id"])
    return sorted(query.execute().data, key=lambda r: (r["doctor_id"], queue_key(r)))


@router.get("/staff/overview")
def staff_overview(day: date = Query(default_factory=clinic_today), actor: dict = Depends(staff_only)):
    query = db().table("hq_appointments").select("doctor_id,status").eq("appointment_date", day.isoformat())
    if actor.get("department_id"):
        query = query.eq("department_id", actor["department_id"])
    appointments = query.execute().data
    rules = []
    if actor.get("department_id"):
        rules = db().table("hq_queue_rules").select("max_patients_per_day,allow_walk_ins").eq("department_id", actor["department_id"]).limit(1).execute().data
    counts: dict[str, int] = {}
    for a in appointments:
        if a["status"] != "cancelled":
            counts[a["doctor_id"]] = counts.get(a["doctor_id"], 0) + 1
    return {"total": sum(counts.values()), "max_patients_per_day": rules[0]["max_patients_per_day"] if rules else 40,
            "allow_walk_ins": rules[0]["allow_walk_ins"] if rules else True, "doctor_counts": counts}


@router.post("/staff/walk-ins", status_code=status.HTTP_201_CREATED)
def register_walk_in(payload: WalkInCreate, request: Request, background: BackgroundTasks, actor: dict = Depends(staff_only)):
    if payload.appointment_date < clinic_today():
        raise HTTPException(status_code=422, detail="Walk-ins cannot be registered for a past date.")
    if not payload.consent_data:
        raise HTTPException(status_code=422, detail="Record that the patient agreed to the use of their data.")
    if payload.priority != "routine" and len((payload.priority_reason or "").strip()) < 3:
        raise HTTPException(status_code=422, detail="Give a short reason for the urgent or emergency priority.")
    doctor = require_doctor(payload.doctor_id)
    if actor.get("department_id") and doctor["department_id"] != actor["department_id"]:
        raise HTTPException(status_code=403, detail="This doctor is outside your department.")
    ensure_doctor_not_on_leave(payload.doctor_id, payload.appointment_date, payload.start_time)

    phone = normalize_phone(payload.patient_phone)
    national_id = normalize_national_id(payload.national_id)
    id_hash = hash_national_id(national_id) if national_id else None

    # Duplicate detection: same phone or national ID as an existing patient account, or already queued today.
    candidates: dict[str, dict] = {}
    for column, value, label in (("phone", phone, "phone"), ("national_id_hash", id_hash, "national_id")):
        if value:
            for row in db().table("hq_profiles").select("id,full_name,phone").eq("role", "patient").eq("is_active", True).eq(column, value).limit(5).execute().data:
                candidates.setdefault(row["id"], {"id": row["id"], "name": mask_name(row["full_name"]),
                                                  "phone_last4": (row.get("phone") or "")[-4:], "match": label})
    same_day = (db().table("hq_appointments").select("id,patient_name,queue_number")
                .eq("appointment_date", payload.appointment_date.isoformat()).eq("patient_phone", phone)
                .in_("status", ["booked", "checked_in", "called", "in_progress", "skipped"]).execute().data)
    same_day = [r for r in same_day if r["patient_name"].casefold() == payload.patient_name.strip().casefold()]
    if same_day:
        raise HTTPException(status_code=409, detail={"code": "already_queued",
            "message": f"{payload.patient_name.strip()} is already in today's queue with token A-{same_day[0]['queue_number']}."})
    link_id = None
    if payload.link_patient_id:
        if str(payload.link_patient_id) not in candidates:
            raise HTTPException(status_code=422, detail="That account does not match the phone or ID entered.")
        link_id = str(payload.link_patient_id)
    elif candidates and not payload.confirm_new:
        raise HTTPException(status_code=409, detail={"code": "possible_duplicate",
            "message": "A patient with this phone number or ID is already registered.", "candidates": list(candidates.values())})

    appointment = rpc("hq_book_appointment", {
        "p_patient_id": link_id, "p_doctor_id": str(payload.doctor_id),
        "p_appointment_date": payload.appointment_date.isoformat(), "p_start_time": payload.start_time.isoformat(),
        "p_source": "walk_in", "p_patient_name": payload.patient_name, "p_patient_phone": phone,
        "p_created_by": actor["id"], "p_priority": payload.priority, "p_priority_reason": payload.priority_reason})
    extra = {}
    if payload.notes:
        extra["notes"] = payload.notes
    if extra:
        db().table("hq_appointments").update(extra).eq("id", appointment["id"]).execute()
        appointment.update(extra)
    subject = {"patient_id": link_id} if link_id else {"appointment_id": appointment["id"]}
    consents = [{**subject, "kind": "data_use", "granted": True, "recorded_by": actor["id"]}]
    if payload.consent_photo:
        consents.append({**subject, "kind": "photo", "granted": True, "recorded_by": actor["id"]})
    db().table("hq_consents").insert(consents).execute()
    audit(actor, "walk_in.created", target_type="appointment", target_id=appointment["id"], patient_id=link_id,
          details={"priority": payload.priority, "linked": bool(link_id)}, request=request, required=False)
    if payload.priority == "emergency":
        notify(str(payload.doctor_id), "Emergency walk-in", f"Token A-{appointment['queue_number']}: {payload.priority_reason}", "warning")
    background.add_task(post_queue_change, str(payload.doctor_id), payload.appointment_date)
    return appointment


def _do_check_in(appointment_id: str, actor: dict) -> dict:
    updated = rpc("hq_check_in", {"p_appointment_id": appointment_id, "p_actor_id": actor["id"],
                                  "p_local_now": clinic_now().replace(tzinfo=None).isoformat()})
    if updated.get("patient_id"):
        note = " You arrived late, so you rejoin at the back of the line." if updated.get("is_late") else ""
        notify(updated["patient_id"], "Checked in", f"Reception checked you in for token A-{updated['queue_number']}.{note}", "warning" if updated.get("is_late") else "success")
    return updated


@router.post("/staff/appointments/{appointment_id}/check-in")
def staff_check_in(appointment_id: UUID, background: BackgroundTasks, actor: dict = Depends(staff_only)):
    appt = _scoped(appointment_id, actor, "id,department_id,doctor_id,appointment_date")
    updated = _do_check_in(str(appointment_id), actor)
    background.add_task(post_queue_change, appt["doctor_id"], clinic_today())
    return updated


@router.post("/staff/check-in")
def staff_check_in_code(payload: CheckInCode, background: BackgroundTasks, actor: dict = Depends(staff_only)):
    rows = db().table("hq_appointments").select("id").eq("checkin_code", str(payload.code)).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Check-in code is not valid.")
    return staff_check_in(UUID(rows[0]["id"]), background, actor)


@router.post("/staff/appointments/{appointment_id}/recall")
def staff_recall(appointment_id: UUID, background: BackgroundTasks, actor: dict = Depends(staff_only)):
    appt = _scoped(appointment_id, actor, "id,department_id,doctor_id")
    updated = rpc("hq_recall_patient", {"p_appointment_id": str(appointment_id), "p_actor_id": actor["id"]})
    background.add_task(post_queue_change, appt["doctor_id"], clinic_today())
    return updated


@router.post("/staff/appointments/{appointment_id}/reschedule")
def staff_reschedule(appointment_id: UUID, payload: AppointmentReschedule, actor: dict = Depends(staff_only)):
    if payload.appointment_date < clinic_today():
        raise HTTPException(status_code=422, detail="Appointments cannot be rescheduled into the past.")
    old = _scoped(appointment_id, actor, "id,status,department_id")
    if old["status"] not in ("booked", "checked_in"):
        raise HTTPException(status_code=409, detail="This appointment cannot be rescheduled.")
    doctor = require_doctor(payload.doctor_id)
    if actor.get("department_id") and doctor["department_id"] != actor["department_id"]:
        raise HTTPException(status_code=403, detail="This doctor is outside your department.")
    ensure_doctor_not_on_leave(payload.doctor_id, payload.appointment_date, payload.start_time)
    return rpc("hq_reschedule_appointment", {
        "p_appointment_id": str(appointment_id), "p_doctor_id": str(payload.doctor_id),
        "p_appointment_date": payload.appointment_date.isoformat(),
        "p_start_time": payload.start_time.isoformat(), "p_actor_id": actor["id"]})


def _set_priority(appointment_id: UUID, payload: PriorityChange, actor: dict) -> dict:
    appt = _scoped(appointment_id, actor, "id,status,department_id,doctor_id,queue_number")
    if appt["status"] not in ("booked", "checked_in", "skipped"):
        raise HTTPException(status_code=409, detail="The priority can only change while the patient is waiting.")
    if payload.priority != "routine" and len((payload.reason or "").strip()) < 3:
        raise HTTPException(status_code=422, detail="Give a short reason for the priority.")
    rows = db().table("hq_appointments").update({
        "priority": payload.priority, "priority_reason": ((payload.reason or "").strip() or None) if payload.priority != "routine" else None,
        "priority_set_by": actor["id"], "updated_at": utc_iso()}).eq("id", str(appointment_id)).execute().data
    add_event(str(appointment_id), actor["id"], "priority_changed", {"priority": payload.priority})
    if payload.priority == "emergency":
        notify(appt["doctor_id"], "Emergency patient", f"Token A-{appt['queue_number']}: {payload.reason}", "warning")
    return rows[0]


@router.post("/staff/appointments/{appointment_id}/priority")
def staff_priority(appointment_id: UUID, payload: PriorityChange, actor: dict = Depends(staff_only)):
    return _set_priority(appointment_id, payload, actor)


# --------------------------------------------------------- identity photos ----
def _photo_subject(appt: dict) -> dict:
    return {"patient_id": appt["patient_id"]} if appt.get("patient_id") else {"appointment_id": appt["id"]}


@router.get("/staff/appointments/{appointment_id}/identity-photo/status")
def staff_photo_status(appointment_id: UUID, actor: dict = Depends(staff_only)):
    appt = _scoped(appointment_id, actor, "id,patient_id,department_id")
    return photo_summary(get_photo(**_photo_subject(appt)))


@router.get("/staff/appointments/{appointment_id}/identity-photo")
def staff_photo_image(appointment_id: UUID, request: Request, actor: dict = Depends(staff_only)):
    appt = _scoped(appointment_id, actor, "id,patient_id,department_id")
    photo = get_photo(**_photo_subject(appt))
    if not photo:
        raise HTTPException(status_code=404, detail="No photo on file.")
    audit(actor, "identity_photo.viewed", target_type="identity_photo", target_id=photo["id"], patient_id=appt.get("patient_id"), request=request)
    return Response(content=photo_bytes(photo), media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


@router.post("/staff/appointments/{appointment_id}/identity-photo", status_code=201)
async def staff_photo_upload(appointment_id: UUID, request: Request, image: UploadFile = File(...),
                             consent_given: bool = Form(default=False), actor: dict = Depends(staff_only)):
    appt = _scoped(appointment_id, actor, "id,patient_id,department_id")
    subject = _photo_subject(appt)
    consent_owner = subject if "patient_id" in subject else subject
    already = has_consent(appt["patient_id"], "photo") if appt.get("patient_id") else bool(
        db().table("hq_consents").select("id").eq("appointment_id", appt["id"]).eq("kind", "photo").eq("granted", True).limit(1).execute().data)
    if not already:
        if not consent_given:
            raise HTTPException(status_code=403, detail="The patient has not consented to a photo. Ask for consent first.")
        db().table("hq_consents").insert({**consent_owner, "kind": "photo", "granted": True, "recorded_by": actor["id"]}).execute()
    raw = await image.read(MEDICAL_IMAGE_MAX_BYTES + 1)
    photo = store_photo(raw=raw, actor=actor, **subject)
    audit(actor, "identity_photo.captured", target_type="identity_photo", target_id=photo["id"], patient_id=appt.get("patient_id"), request=request)
    return photo_summary(photo)


@router.post("/staff/identity-photo/{photo_id}/confirm")
def staff_photo_confirm(photo_id: UUID, payload: PhotoConfirm, request: Request, actor: dict = Depends(staff_only)):
    if not payload.id_document_checked:
        raise HTTPException(status_code=422, detail="Confirm that you compared the photo with the patient's ID.")
    photo = confirm_photo(photo_id, actor)
    audit(actor, "identity_photo.confirmed", target_type="identity_photo", target_id=str(photo_id), patient_id=photo.get("patient_id"), request=request)
    return photo_summary(photo)


# ------------------------------------------------------------------- nurse ----
@router.get("/nurse/queue")
def nurse_queue(day: date = Query(default_factory=clinic_today), actor: dict = Depends(nurse_only)):
    query = (db().table("hq_appointments").select(LIST_SELECT).eq("appointment_date", day.isoformat())
             .in_("status", ["checked_in", "called", "in_progress"]))
    if actor.get("department_id"):
        query = query.eq("department_id", actor["department_id"])
    rows = query.execute().data
    return sorted(rows, key=lambda r: (r["triage_status"] == "done", queue_key(r)))


@router.get("/nurse/appointments/{appointment_id}/triage")
def nurse_get_triage(appointment_id: UUID, request: Request, actor: dict = Depends(nurse_only)):
    appt = _scoped(appointment_id, actor, "id,patient_id,department_id")
    audit(actor, "clinical.vitals_viewed", target_type="appointment", target_id=str(appointment_id), patient_id=appt.get("patient_id"), request=request)
    rows = db().table("hq_triage_vitals").select("*").eq("appointment_id", str(appointment_id)).order("recorded_at", desc=True).limit(1).execute().data
    return rows[0] if rows else None


@router.post("/nurse/appointments/{appointment_id}/triage", status_code=201)
def nurse_save_triage(appointment_id: UUID, payload: TriageSave, request: Request, background: BackgroundTasks, actor: dict = Depends(nurse_only)):
    appt = _scoped(appointment_id, actor, "id,status,patient_id,department_id,doctor_id,queue_number")
    if appt["status"] != "checked_in":
        raise HTTPException(status_code=409, detail="Triage can be recorded only for a checked-in patient who is still waiting.")
    vitals = payload.model_dump(exclude={"priority", "priority_reason"}, exclude_none=True)
    if not any(k not in ("chief_complaint", "notes") for k in vitals) and not vitals.get("chief_complaint"):
        raise HTTPException(status_code=422, detail="Enter at least one vital sign or the main complaint.")
    saved = db().table("hq_triage_vitals").insert({"appointment_id": str(appointment_id), "recorded_by": actor["id"], **vitals}).execute().data[0]
    db().table("hq_appointments").update({"triage_status": "done", "triage_done_at": utc_iso(), "updated_at": utc_iso()}).eq("id", str(appointment_id)).execute()
    add_event(str(appointment_id), actor["id"], "triage_done")
    audit(actor, "clinical.vitals_recorded", target_type="appointment", target_id=str(appointment_id), patient_id=appt.get("patient_id"), request=request)
    _set_priority(appointment_id, PriorityChange(priority=payload.priority, reason=payload.priority_reason), actor)
    if appt.get("patient_id"):
        notify(appt["patient_id"], "Triage complete", "Your vital signs were recorded. The doctor will call you soon.", "info")
    background.add_task(post_queue_change, appt["doctor_id"], clinic_today())
    return saved


@router.post("/nurse/appointments/{appointment_id}/priority")
def nurse_priority(appointment_id: UUID, payload: PriorityChange, actor: dict = Depends(nurse_only)):
    return _set_priority(appointment_id, payload, actor)
