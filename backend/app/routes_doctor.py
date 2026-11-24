import math
from datetime import date, datetime, timezone
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from .common import (
    MEDICAL_RECORDS_BUCKET, add_event, audit, average_consult_minutes, clinic_today, db, normalize_national_id,
    normalize_phone, hash_national_id, notify, one, require_doctor, rpc, mask_name, queue_key, utc_iso, first,
)
from .photos import get_photo, photo_bytes, photo_summary
from .security import require_roles
from .sms import post_queue_change

router = APIRouter(prefix="/api/v1/doctor", tags=["doctor"])
doctor_only = require_roles("doctor")

QUEUE_COLUMNS = ("id,source,patient_name,patient_id,doctor_id,department_id,appointment_date,start_time,queue_number,"
                 "queue_sort,status,priority,priority_reason,triage_status,is_late,recall_count,called_at,started_at,"
                 "checked_in_at,completed_at,referred_from_doctor_id,dependent_id")
RECORD_COLUMNS = "id,patient_id,appointment_id,record_type,title,original_filename,content_type,file_size_bytes,created_at"


class PriorityChange(BaseModel):
    priority: Literal["emergency", "urgent", "routine"]
    reason: str | None = Field(default=None, max_length=200)


class ConsultationSave(BaseModel):
    note_text: str = Field(default="", max_length=20000)
    note_source: Literal["typed", "dictated", "mixed"] = "typed"
    diagnosis: str | None = Field(default=None, max_length=500)
    summary_en: str | None = Field(default=None, max_length=4000)
    summary_ur: str | None = Field(default=None, max_length=4000)
    instructions_en: str | None = Field(default=None, max_length=2000)
    instructions_ur: str | None = Field(default=None, max_length=2000)
    follow_up_date: date | None = None
    follow_up_note: str | None = Field(default=None, max_length=500)


class RxItem(BaseModel):
    medicine: str = Field(min_length=1, max_length=120)
    dose: str | None = Field(default=None, max_length=60)
    frequency: str | None = Field(default=None, max_length=60)
    duration: str | None = Field(default=None, max_length=60)
    instructions: str | None = Field(default=None, max_length=200)


class PrescriptionSave(BaseModel):
    items: list[RxItem] = Field(max_length=30)
    advice: str | None = Field(default=None, max_length=2000)


class ReferralCreate(BaseModel):
    to_doctor_id: UUID
    reason: str = Field(min_length=3, max_length=300)


class BreakGlassLookup(BaseModel):
    phone: str | None = Field(default=None, max_length=32)
    national_id: str | None = Field(default=None, max_length=32)


class BreakGlassOpen(BaseModel):
    patient_id: UUID
    reason: str = Field(min_length=15, max_length=500)
    minutes: int = Field(default=30, ge=5, le=60)


class AvailabilitySlot(BaseModel):
    weekday: int = Field(ge=0, le=6)
    start_time: str
    end_time: str
    is_break: bool = False


class TimeOffCreate(BaseModel):
    starts_at: datetime
    ends_at: datetime
    reason: str | None = Field(default=None, max_length=500)


def _assigned(appointment_id: UUID, actor: dict, statuses: tuple[str, ...], columns: str = QUEUE_COLUMNS) -> dict:
    rows = (db().table("hq_appointments").select(columns).eq("id", str(appointment_id))
            .eq("doctor_id", actor["id"]).in_("status", list(statuses)).limit(1).execute().data)
    if not rows:
        raise HTTPException(status_code=403, detail="This patient is not currently assigned to you.")
    return rows[0]


def _rules(department_id: str) -> dict:
    rows = db().table("hq_queue_rules").select("*").eq("department_id", department_id).limit(1).execute().data
    return rows[0] if rows else {"grace_minutes": 10, "late_after_minutes": 15}


# ------------------------------------------------------------------- queue ----
@router.get("/queue")
def doctor_queue(day: date = Query(default_factory=clinic_today), actor: dict = Depends(doctor_only)):
    rows = (db().table("hq_appointments").select(QUEUE_COLUMNS).eq("doctor_id", actor["id"])
            .eq("appointment_date", day.isoformat()).execute().data)
    # active patients first, in calling order; finished ones after
    order = {"called": 0, "in_progress": 0, "checked_in": 1, "skipped": 2, "booked": 3}
    return sorted(rows, key=lambda r: (order.get(r["status"], 9), queue_key(r)))


@router.get("/overview")
def doctor_overview(day: date = Query(default_factory=clinic_today), actor: dict = Depends(doctor_only)):
    rows = db().table("hq_appointments").select("id,status,queue_number").eq("doctor_id", actor["id"]).eq("appointment_date", day.isoformat()).execute().data
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    serving = next((r["queue_number"] for r in rows if r["status"] in ("called", "in_progress")), None)
    return {"appointments": len(rows), "completed": counts.get("completed", 0), "no_show": counts.get("no_show", 0),
            "serving": serving, "status_counts": counts,
            "grace_minutes": _rules(actor["department_id"])["grace_minutes"] if actor.get("department_id") else 10,
            "avg_consult_minutes": average_consult_minutes(actor["id"], actor.get("department_id"))}


@router.post("/queue/next")
def doctor_call_next(request: Request, background: BackgroundTasks, actor: dict = Depends(doctor_only)):
    appointment = rpc("hq_call_next_patient", {
        "p_doctor_id": actor["id"], "p_actor_id": actor["id"], "p_queue_date": clinic_today().isoformat()})
    if not appointment:
        return {"appointment": None, "message": "No checked-in patients are waiting."}
    audit(actor, "queue.call_next", target_type="appointment", target_id=appointment["id"],
          patient_id=appointment.get("patient_id"), request=request, required=False)
    background.add_task(post_queue_change, actor["id"], clinic_today())
    subject = {"patient_id": appointment["patient_id"]} if appointment.get("patient_id") else {"appointment_id": appointment["id"]}
    photo = get_photo(**subject)
    if not photo and appointment.get("patient_id"):
        photo = get_photo(appointment_id=appointment["id"])
    return {"appointment": appointment, "identity": photo_summary(photo)}


@router.post("/appointments/{appointment_id}/start")
def doctor_start(appointment_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    appt = rpc("hq_start_consultation", {"p_appointment_id": str(appointment_id), "p_doctor_id": actor["id"]})
    audit(actor, "consultation.started", target_type="appointment", target_id=str(appointment_id),
          patient_id=appt.get("patient_id"), request=request, required=False)
    return appt


@router.post("/appointments/{appointment_id}/complete")
def doctor_complete(appointment_id: UUID, background: BackgroundTasks, actor: dict = Depends(doctor_only)):
    rows = (db().table("hq_appointments").update({"status": "completed", "completed_at": utc_iso(), "updated_at": utc_iso()})
            .eq("id", str(appointment_id)).eq("doctor_id", actor["id"]).eq("status", "in_progress").execute().data)
    if not rows:
        raise HTTPException(status_code=409, detail="Start the consultation before completing it.")
    add_event(str(appointment_id), actor["id"], "completed")
    if rows[0].get("patient_id"):
        notify(rows[0]["patient_id"], "Visit completed", "Your visit summary is ready. You can also leave feedback.", "success")
    background.add_task(post_queue_change, actor["id"], clinic_today())
    return rows[0]


@router.post("/appointments/{appointment_id}/skip")
def doctor_skip(appointment_id: UUID, background: BackgroundTasks, actor: dict = Depends(doctor_only)):
    _assigned(appointment_id, actor, ("called", "checked_in"))
    appt = rpc("hq_skip_patient", {"p_appointment_id": str(appointment_id), "p_actor_id": actor["id"]})
    background.add_task(post_queue_change, actor["id"], clinic_today())
    return appt


@router.post("/appointments/{appointment_id}/recall")
def doctor_recall(appointment_id: UUID, background: BackgroundTasks, actor: dict = Depends(doctor_only)):
    _assigned(appointment_id, actor, ("skipped",))
    appt = rpc("hq_recall_patient", {"p_appointment_id": str(appointment_id), "p_actor_id": actor["id"]})
    background.add_task(post_queue_change, actor["id"], clinic_today())
    return appt


@router.post("/appointments/{appointment_id}/no-show")
def doctor_no_show(appointment_id: UUID, actor: dict = Depends(doctor_only)):
    appt = _assigned(appointment_id, actor, ("called", "skipped"))
    if appt["status"] == "called" and appt.get("called_at"):
        grace = _rules(appt["department_id"])["grace_minutes"]
        elapsed = (datetime.now(timezone.utc) - datetime.fromisoformat(appt["called_at"])).total_seconds() / 60
        if elapsed < grace:
            raise HTTPException(status_code=409, detail=f"The grace timer is still running ({math.ceil(grace - elapsed)} min left). Skip the patient to recall them later.")
    rows = db().table("hq_appointments").update({"status": "no_show", "updated_at": utc_iso()}).eq("id", str(appointment_id)).execute().data
    add_event(str(appointment_id), actor["id"], "no_show")
    if rows[0].get("patient_id"):
        notify(rows[0]["patient_id"], "You missed your turn", "Contact reception to book another visit.", "warning", sms=True)
    return rows[0]


@router.post("/appointments/{appointment_id}/priority")
def doctor_priority(appointment_id: UUID, payload: PriorityChange, actor: dict = Depends(doctor_only)):
    _assigned(appointment_id, actor, ("checked_in", "booked", "skipped"))
    if payload.priority != "routine" and len((payload.reason or "").strip()) < 3:
        raise HTTPException(status_code=422, detail="Give a short reason for the priority.")
    rows = db().table("hq_appointments").update({
        "priority": payload.priority, "priority_reason": (payload.reason or "").strip() or None if payload.priority != "routine" else None,
        "priority_set_by": actor["id"], "updated_at": utc_iso()}).eq("id", str(appointment_id)).execute().data
    add_event(str(appointment_id), actor["id"], "priority_changed", {"priority": payload.priority})
    return rows[0]


@router.post("/appointments/{appointment_id}/refer")
def doctor_refer(appointment_id: UUID, payload: ReferralCreate, request: Request, background: BackgroundTasks, actor: dict = Depends(doctor_only)):
    require_doctor(payload.to_doctor_id)
    appt = rpc("hq_refer_appointment", {
        "p_appointment_id": str(appointment_id), "p_from_doctor": actor["id"], "p_to_doctor": str(payload.to_doctor_id),
        "p_reason": payload.reason, "p_actor_id": actor["id"]})
    notify(str(payload.to_doctor_id), "Patient referred to you", f"Token A-{appt['queue_number']} from Dr. {actor['full_name']}: {payload.reason}", "info")
    audit(actor, "referral.created", target_type="appointment", target_id=str(appointment_id),
          patient_id=appt.get("patient_id"), details={"to": str(payload.to_doctor_id)}, request=request, required=False)
    background.add_task(post_queue_change, actor["id"], clinic_today())
    background.add_task(post_queue_change, str(payload.to_doctor_id), clinic_today())
    return appt


# ------------------------------------------------------- identity and chart ----
@router.get("/appointments/{appointment_id}/identity-photo")
def doctor_identity_photo(appointment_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    appt = _assigned(appointment_id, actor, ("called", "in_progress"))
    photo = (get_photo(patient_id=appt["patient_id"]) if appt.get("patient_id") else None) or get_photo(appointment_id=appt["id"])
    if not photo:
        raise HTTPException(status_code=404, detail="No identity photo is on file.")
    audit(actor, "identity_photo.viewed", target_type="identity_photo", target_id=photo["id"], patient_id=appt.get("patient_id"), request=request)
    return Response(content=photo_bytes(photo), media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


def _chart(patient_id: str | None, appointment_id: str) -> dict:
    """Clinical history for one patient. Callers must already have recorded the access in the audit log."""
    vitals = (db().table("hq_triage_vitals").select("*").eq("appointment_id", appointment_id)
              .order("recorded_at", desc=True).limit(1).execute().data)
    out = {"records": [], "visits": [], "prescriptions": [], "triage": vitals[0] if vitals else None}
    if not patient_id:
        return out
    out["records"] = db().table("hq_medical_records").select(RECORD_COLUMNS).eq("patient_id", patient_id).order("created_at", desc=True).execute().data
    out["visits"] = (db().table("hq_appointments").select(
        "id,appointment_date,start_time,queue_number,status,department:hq_departments(name),"
        "doctor:hq_profiles!hq_appointments_doctor_id_fkey(full_name,specialty)")
        .eq("patient_id", patient_id).eq("status", "completed").order("appointment_date", desc=True).limit(50).execute().data)
    out["prescriptions"] = (db().table("hq_prescriptions").select(
        "id,items,advice,created_at,doctor:hq_profiles!hq_prescriptions_doctor_id_fkey(full_name)")
        .eq("patient_id", patient_id).order("created_at", desc=True).limit(20).execute().data)
    return out


@router.get("/appointments/{appointment_id}/medical-history")
def doctor_patient_medical_history(appointment_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    visit = _assigned(appointment_id, actor, ("called", "in_progress"))
    audit(actor, "clinical.history_viewed", target_type="appointment", target_id=str(appointment_id),
          patient_id=visit.get("patient_id"), request=request)
    return {"patient_name": visit["patient_name"], **_chart(visit.get("patient_id"), visit["id"])}


@router.get("/appointments/{appointment_id}/medical-records/{record_id}/image")
def doctor_patient_medical_record_image(appointment_id: UUID, record_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    visit = _assigned(appointment_id, actor, ("called", "in_progress"))
    if not visit.get("patient_id"):
        raise HTTPException(status_code=404, detail="Medical record not found.")
    rows = db().table("hq_medical_records").select("storage_path").eq("id", str(record_id)).eq("patient_id", visit["patient_id"]).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Medical record not found.")
    audit(actor, "clinical.record_image_viewed", target_type="medical_record", target_id=str(record_id), patient_id=visit["patient_id"], request=request)
    try:
        data = db().storage.from_(MEDICAL_RECORDS_BUCKET).download(rows[0]["storage_path"])
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The medical image could not be loaded.") from exc
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


# ------------------------------------------- consultation and prescription ----
def _writable_visit(appointment_id: UUID, actor: dict) -> dict:
    appt = _assigned(appointment_id, actor, ("in_progress", "completed"))
    if appt["status"] == "completed" and appt.get("completed_at"):
        if (datetime.now(timezone.utc) - datetime.fromisoformat(appt["completed_at"])).total_seconds() > 24 * 3600:
            raise HTTPException(status_code=409, detail="Notes can only be edited within 24 hours of completing the visit.")
    return appt


@router.get("/appointments/{appointment_id}/consultation")
def get_consultation(appointment_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    appt = _assigned(appointment_id, actor, ("called", "in_progress", "completed"))
    audit(actor, "clinical.consultation_viewed", target_type="appointment", target_id=str(appointment_id), patient_id=appt.get("patient_id"), request=request)
    consult = db().table("hq_consultations").select("*").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    rx = db().table("hq_prescriptions").select("*").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    follow = db().table("hq_followups").select("suggested_date,note,status").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    return {"consultation": consult[0] if consult else None, "prescription": rx[0] if rx else None, "follow_up": follow[0] if follow else None}


@router.put("/appointments/{appointment_id}/consultation")
def save_consultation(appointment_id: UUID, payload: ConsultationSave, request: Request, actor: dict = Depends(doctor_only)):
    appt = _writable_visit(appointment_id, actor)
    record = {"appointment_id": str(appointment_id), "patient_id": appt.get("patient_id"), "doctor_id": actor["id"],
              "note_text": payload.note_text, "note_source": payload.note_source, "diagnosis": payload.diagnosis,
              "summary_en": payload.summary_en, "summary_ur": payload.summary_ur,
              "instructions_en": payload.instructions_en, "instructions_ur": payload.instructions_ur, "updated_at": utc_iso()}
    saved = db().table("hq_consultations").upsert(record, on_conflict="appointment_id").execute().data[0]
    audit(actor, "clinical.consultation_saved", target_type="appointment", target_id=str(appointment_id), patient_id=appt.get("patient_id"), request=request)
    follow = None
    if payload.follow_up_date:
        if payload.follow_up_date <= clinic_today():
            raise HTTPException(status_code=422, detail="Pick a follow-up date after today.")
        if not appt.get("patient_id"):
            raise HTTPException(status_code=422, detail="Follow-up booking needs a registered patient account.")
        previous = db().table("hq_followups").select("suggested_date").eq("appointment_id", str(appointment_id)).limit(1).execute().data
        follow = db().table("hq_followups").upsert({
            "appointment_id": str(appointment_id), "patient_id": appt["patient_id"], "doctor_id": actor["id"],
            "dependent_id": appt.get("dependent_id"), "suggested_date": payload.follow_up_date.isoformat(),
            "note": payload.follow_up_note, "status": "open"}, on_conflict="appointment_id").execute().data[0]
        if not previous or previous[0]["suggested_date"] != payload.follow_up_date.isoformat():
            notify(appt["patient_id"], "Follow-up recommended", f"Dr. {actor['full_name']} suggests a follow-up on {payload.follow_up_date:%d %b %Y}. Open the app to book it.", "info", sms=True)
    return {"consultation": saved, "follow_up": follow}


@router.put("/appointments/{appointment_id}/prescription")
def save_prescription(appointment_id: UUID, payload: PrescriptionSave, request: Request, actor: dict = Depends(doctor_only)):
    appt = _writable_visit(appointment_id, actor)
    existing = db().table("hq_prescriptions").select("id").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    saved = db().table("hq_prescriptions").upsert({
        "appointment_id": str(appointment_id), "patient_id": appt.get("patient_id"), "doctor_id": actor["id"],
        "items": [i.model_dump() for i in payload.items], "advice": payload.advice, "updated_at": utc_iso(),
    }, on_conflict="appointment_id").execute().data[0]
    audit(actor, "clinical.prescription_saved", target_type="appointment", target_id=str(appointment_id), patient_id=appt.get("patient_id"), request=request)
    if appt.get("patient_id") and not existing and payload.items:
        notify(appt["patient_id"], "Your prescription is ready", "Open Visits to view or download it.", "success")
    return saved


# ------------------------------------------------------------- break-glass ----
@router.post("/break-glass/lookup")
def break_glass_lookup(payload: BreakGlassLookup, request: Request, actor: dict = Depends(doctor_only)):
    """Find a patient by exact phone or national ID. Only a masked name is returned."""
    if not (payload.phone or payload.national_id):
        raise HTTPException(status_code=422, detail="Enter the patient's phone number or national ID.")
    query = db().table("hq_profiles").select("id,full_name,national_id_last4,dob").eq("role", "patient").eq("is_active", True)
    if payload.national_id:
        query = query.eq("national_id_hash", hash_national_id(normalize_national_id(payload.national_id)))
    else:
        query = query.eq("phone", normalize_phone(payload.phone))
    rows = query.limit(5).execute().data
    audit(actor, "break_glass.lookup", details={"matches": len(rows)}, request=request)
    return [{"id": r["id"], "name": mask_name(r["full_name"]), "id_last4": r.get("national_id_last4"), "dob": r.get("dob")} for r in rows]


@router.post("/break-glass")
def break_glass_open(payload: BreakGlassOpen, request: Request, actor: dict = Depends(doctor_only)):
    row = rpc("hq_break_glass_open", {"p_doctor_id": actor["id"], "p_patient_id": str(payload.patient_id),
                                      "p_reason": payload.reason, "p_minutes": payload.minutes})
    return row


@router.get("/break-glass")
def break_glass_mine(actor: dict = Depends(doctor_only)):
    return (db().table("hq_break_glass").select("id,patient_id,reason,opened_at,expires_at,closed_at,review_outcome")
            .eq("doctor_id", actor["id"]).order("opened_at", desc=True).limit(20).execute().data)


def _active_break_glass(session_id: UUID, actor: dict) -> dict:
    rows = db().table("hq_break_glass").select("*").eq("id", str(session_id)).eq("doctor_id", actor["id"]).limit(1).execute().data
    if not rows or rows[0]["closed_at"] or rows[0]["expires_at"] <= utc_iso():
        raise HTTPException(status_code=403, detail="Emergency access has expired. Open a new session if it is still needed.")
    return rows[0]


@router.get("/break-glass/{session_id}/history")
def break_glass_history(session_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    session = _active_break_glass(session_id, actor)
    audit(actor, "break_glass.history_viewed", target_type="break_glass", target_id=str(session_id), patient_id=session["patient_id"], request=request)
    patient = one("hq_profiles", session["patient_id"], "full_name")
    return {"patient_name": patient["full_name"], "expires_at": session["expires_at"], **_chart(session["patient_id"], "00000000-0000-0000-0000-000000000000")}


@router.get("/break-glass/{session_id}/records/{record_id}/image")
def break_glass_record_image(session_id: UUID, record_id: UUID, request: Request, actor: dict = Depends(doctor_only)):
    session = _active_break_glass(session_id, actor)
    rows = db().table("hq_medical_records").select("storage_path").eq("id", str(record_id)).eq("patient_id", session["patient_id"]).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Medical record not found.")
    audit(actor, "break_glass.record_image_viewed", target_type="medical_record", target_id=str(record_id), patient_id=session["patient_id"], request=request)
    data = db().storage.from_(MEDICAL_RECORDS_BUCKET).download(rows[0]["storage_path"])
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


@router.post("/break-glass/{session_id}/close")
def break_glass_close(session_id: UUID, actor: dict = Depends(doctor_only)):
    rows = db().table("hq_break_glass").update({"closed_at": utc_iso()}).eq("id", str(session_id)).eq("doctor_id", actor["id"]).is_("closed_at", "null").execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Session not found.")
    return {"closed": True}


# ------------------------------------------------------------ availability ----
@router.put("/availability")
def update_availability(slots: list[AvailabilitySlot], actor: dict = Depends(doctor_only)):
    db().table("hq_doctor_availability").delete().eq("doctor_id", actor["id"]).execute()
    rows = [{**slot.model_dump(mode="json"), "doctor_id": actor["id"]} for slot in slots]
    if rows:
        db().table("hq_doctor_availability").insert(rows).execute()
    return {"availability": rows}


@router.post("/time-off")
def doctor_time_off(payload: TimeOffCreate, actor: dict = Depends(doctor_only)):
    if payload.ends_at <= payload.starts_at:
        raise HTTPException(status_code=422, detail="End time must be after start time.")
    return db().table("hq_doctor_time_off").insert({
        "doctor_id": actor["id"], "starts_at": payload.starts_at.isoformat(), "ends_at": payload.ends_at.isoformat(),
        "reason": payload.reason, "created_by": actor["id"]}).execute().data[0]


@router.get("/time-off")
def doctor_time_off_list(actor: dict = Depends(doctor_only)):
    return db().table("hq_doctor_time_off").select("*").eq("doctor_id", actor["id"]).gte("ends_at", utc_iso()).order("starts_at").execute().data
