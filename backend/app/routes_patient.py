from datetime import date, datetime, time
from typing import Literal
from uuid import UUID, uuid4

from fastapi import APIRouter, BackgroundTasks, Depends, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import Response
from pydantic import BaseModel, Field

from .common import (
    ACTIVE_STATUSES, MEDICAL_IMAGE_MAX_BYTES, MEDICAL_RECORDS_BUCKET, add_event, audit, average_consult_minutes,
    clinic_now, clinic_today, compress_medical_image, db, ensure_doctor_not_on_leave, medical_record_metadata,
    notify, one, require_doctor, rpc, queue_key, utc_iso,
)
from .pdf import prescription_pdf
from .photos import get_photo, has_consent, photo_summary, store_photo
from .security import require_roles
from .sms import flush_sms_outbox

router = APIRouter(prefix="/api/v1/patient", tags=["patient"])
patient_only = require_roles("patient")

APPT_SELECT = ("*,doctor:hq_profiles!hq_appointments_doctor_id_fkey(full_name,specialty,room),"
               "department:hq_departments(name),dependent:hq_dependents(full_name)")


class AppointmentCreate(BaseModel):
    doctor_id: UUID
    appointment_date: date
    start_time: time
    notes: str | None = Field(default=None, max_length=1000)
    dependent_id: UUID | None = None
    follow_up_id: UUID | None = None


class AppointmentReschedule(BaseModel):
    doctor_id: UUID
    appointment_date: date
    start_time: time


class CheckInCode(BaseModel):
    code: UUID


class FeedbackCreate(BaseModel):
    appointment_id: UUID
    rating: int = Field(ge=1, le=5)
    comment: str | None = Field(default=None, max_length=2000)


class DependentCreate(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    relation: Literal["child", "parent", "spouse", "other"] = "child"
    dob: date | None = None


class ConsentUpdate(BaseModel):
    photo: bool


def _own_appointment(appointment_id: UUID, actor: dict, columns: str = "*") -> dict:
    rows = db().table("hq_appointments").select(columns).eq("id", str(appointment_id)).eq("patient_id", actor["id"]).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Appointment not found.")
    return rows[0]


# ----------------------------------------------------------------- booking ----
@router.post("/appointments", status_code=status.HTTP_201_CREATED)
def book_appointment(payload: AppointmentCreate, actor: dict = Depends(patient_only)):
    if payload.appointment_date < clinic_today():
        raise HTTPException(status_code=422, detail="Appointments cannot be booked in the past.")
    doctor = require_doctor(payload.doctor_id)
    ensure_doctor_not_on_leave(payload.doctor_id, payload.appointment_date, payload.start_time)
    follow_up = None
    if payload.follow_up_id:
        rows = db().table("hq_followups").select("*").eq("id", str(payload.follow_up_id)).eq("patient_id", actor["id"]).eq("status", "open").limit(1).execute().data
        if not rows:
            raise HTTPException(status_code=404, detail="This follow-up is no longer open.")
        follow_up = rows[0]
    appointment = rpc("hq_book_appointment", {
        "p_patient_id": actor["id"], "p_doctor_id": str(payload.doctor_id),
        "p_appointment_date": payload.appointment_date.isoformat(), "p_start_time": payload.start_time.isoformat(),
        "p_source": "appointment", "p_patient_name": actor["full_name"], "p_patient_phone": actor.get("phone"),
        "p_created_by": actor["id"], "p_dependent_id": str(payload.dependent_id) if payload.dependent_id else None,
    })
    extra = {}
    if payload.notes:
        extra["notes"] = payload.notes
    if follow_up:
        extra["follow_up_of"] = follow_up["appointment_id"]
        db().table("hq_followups").update({"status": "booked", "booked_appointment_id": appointment["id"]}).eq("id", follow_up["id"]).execute()
    if extra:
        db().table("hq_appointments").update(extra).eq("id", appointment["id"]).execute()
        appointment.update(extra)
    notify(actor["id"], "Booking confirmed",
           f"Your appointment with Dr. {doctor['full_name']} on {payload.appointment_date:%d %b} at {payload.start_time:%H:%M} is booked.", "success")
    return appointment


@router.get("/appointments")
def patient_appointments(actor: dict = Depends(patient_only), upcoming: bool | None = None):
    query = (db().table("hq_appointments").select(APPT_SELECT).eq("patient_id", actor["id"])
             .order("appointment_date", desc=True).order("queue_number", desc=True).limit(200))
    if upcoming:
        query = query.gte("appointment_date", clinic_today().isoformat()).in_("status", ACTIVE_STATUSES)
    return query.execute().data


@router.post("/appointments/{appointment_id}/cancel")
def cancel_appointment(appointment_id: UUID, actor: dict = Depends(patient_only)):
    rows = (db().table("hq_appointments").update({"status": "cancelled", "updated_at": utc_iso()})
            .eq("id", str(appointment_id)).eq("patient_id", actor["id"]).in_("status", ["booked", "checked_in"]).execute().data)
    if not rows:
        raise HTTPException(status_code=409, detail="This appointment can no longer be cancelled.")
    add_event(str(appointment_id), actor["id"], "cancelled")
    notify(actor["id"], "Appointment cancelled", "Your appointment was cancelled.", "warning")
    return rows[0]


@router.post("/appointments/{appointment_id}/reschedule")
def patient_reschedule(appointment_id: UUID, payload: AppointmentReschedule, actor: dict = Depends(patient_only)):
    if payload.appointment_date < clinic_today():
        raise HTTPException(status_code=422, detail="Appointments cannot be rescheduled into the past.")
    current = _own_appointment(appointment_id, actor, "id,status")
    if current["status"] not in ("booked", "checked_in"):
        raise HTTPException(status_code=409, detail="This appointment cannot be rescheduled.")
    require_doctor(payload.doctor_id)
    ensure_doctor_not_on_leave(payload.doctor_id, payload.appointment_date, payload.start_time)
    return rpc("hq_reschedule_appointment", {
        "p_appointment_id": str(appointment_id), "p_doctor_id": str(payload.doctor_id),
        "p_appointment_date": payload.appointment_date.isoformat(),
        "p_start_time": payload.start_time.isoformat(), "p_actor_id": actor["id"]})


# --------------------------------------------------------------- live queue ----
@router.get("/queue/{appointment_id}")
def patient_queue(appointment_id: UUID, actor: dict = Depends(patient_only)):
    appointment = _own_appointment(appointment_id, actor, APPT_SELECT)
    rows = (db().table("hq_appointments").select("queue_number,queue_sort,priority,status")
            .eq("doctor_id", appointment["doctor_id"]).eq("appointment_date", appointment["appointment_date"])
            .in_("status", ["checked_in", "called", "in_progress"]).execute().data)
    # The tracker exposes token numbers only, never other patients' details.
    serving_rows = [r for r in rows if r["status"] in ("called", "in_progress")]
    mine = queue_key(appointment)
    waiting_ahead = sum(1 for r in rows if r["status"] == "checked_in" and queue_key(r) < mine
                        and r["queue_number"] != appointment["queue_number"])
    ahead = waiting_ahead + len(serving_rows)
    avg = average_consult_minutes(appointment["doctor_id"], appointment.get("department_id"))
    eta = None
    if appointment["status"] in ("booked", "checked_in", "skipped"):
        eta = int(round(waiting_ahead * avg + (avg / 2 if serving_rows else 0)))
    triage = appointment.get("triage_status")
    stage = {"booked": "booked", "checked_in": "triage" if triage == "done" else "waiting",
             "called": "consultation", "in_progress": "consultation", "completed": "done",
             "skipped": "skipped"}.get(appointment["status"], appointment["status"])
    return {"appointment": appointment, "people_ahead": ahead, "waiting_ahead": waiting_ahead,
            "now_serving": {"queue_number": serving_rows[0]["queue_number"]} if serving_rows else None,
            "estimated_wait_minutes": eta, "avg_consult_minutes": avg, "stage": stage,
            "triage_done": triage == "done", "server_time": utc_iso()}


@router.post("/check-in")
def patient_check_in(payload: CheckInCode, actor: dict = Depends(patient_only)):
    """Checking in from home would let anyone queue-jump, so arrival is confirmed by reception scanning the QR code."""
    raise HTTPException(status_code=403, detail="Check in at reception by showing your QR code.")


def _check_in(appointment: dict, actor: dict) -> dict:
    if appointment["status"] == "skipped":
        updated = rpc("hq_recall_patient", {"p_appointment_id": appointment["id"], "p_actor_id": actor["id"]})
        notify(actor["id"], "Back in the queue", "You rejoined the queue at the end of the line.", "info")
        return updated
    updated = rpc("hq_check_in", {"p_appointment_id": appointment["id"], "p_actor_id": actor["id"],
                                  "p_local_now": clinic_now().replace(tzinfo=None).isoformat()})
    message = (f"You arrived late, so token A-{updated['queue_number']} rejoined at the back of the line."
               if updated.get("is_late") else f"You are checked in with token A-{updated['queue_number']}.")
    notify(actor["id"], "Checked in", message, "warning" if updated.get("is_late") else "success")
    return updated


@router.post("/appointments/{appointment_id}/here")
def patient_here(appointment_id: UUID, actor: dict = Depends(patient_only)):
    """'I am here': rejoin the queue after being skipped."""
    appointment = _own_appointment(appointment_id, actor, "id,status,queue_number")
    if appointment["status"] != "skipped":
        raise HTTPException(status_code=409, detail="You are not waiting to be recalled.")
    return _check_in(appointment, actor)


@router.post("/feedback", status_code=status.HTTP_201_CREATED)
def patient_feedback(payload: FeedbackCreate, actor: dict = Depends(patient_only)):
    appt = _own_appointment(payload.appointment_id, actor, "id,status")
    if appt["status"] != "completed":
        raise HTTPException(status_code=409, detail="Feedback is available after a completed visit.")
    return db().table("hq_feedback").insert({
        "appointment_id": str(payload.appointment_id), "patient_id": actor["id"],
        "rating": payload.rating, "comment": payload.comment}).execute().data[0]


# -------------------------------------------------------------- dependents ----
@router.get("/dependents")
def list_dependents(actor: dict = Depends(patient_only)):
    return db().table("hq_dependents").select("id,full_name,relation,dob").eq("guardian_id", actor["id"]).eq("is_active", True).order("created_at").execute().data


@router.post("/dependents", status_code=status.HTTP_201_CREATED)
def add_dependent(payload: DependentCreate, actor: dict = Depends(patient_only)):
    count = len(db().table("hq_dependents").select("id").eq("guardian_id", actor["id"]).eq("is_active", True).execute().data)
    if count >= 10:
        raise HTTPException(status_code=409, detail="You can add up to 10 family members.")
    return db().table("hq_dependents").insert({
        "guardian_id": actor["id"], "full_name": " ".join(payload.full_name.split()), "relation": payload.relation,
        "dob": payload.dob.isoformat() if payload.dob else None}).execute().data[0]


@router.delete("/dependents/{dependent_id}")
def remove_dependent(dependent_id: UUID, actor: dict = Depends(patient_only)):
    rows = db().table("hq_dependents").update({"is_active": False}).eq("id", str(dependent_id)).eq("guardian_id", actor["id"]).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Family member not found.")
    return {"removed": True}


# ------------------------------------------- visit summaries, prescriptions ----
@router.get("/visits/{appointment_id}/summary")
def visit_summary(appointment_id: UUID, actor: dict = Depends(patient_only)):
    appt = _own_appointment(appointment_id, actor, APPT_SELECT)
    consult = db().table("hq_consultations").select("diagnosis,summary_en,summary_ur,instructions_en,instructions_ur,updated_at").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    rx = db().table("hq_prescriptions").select("id,items,advice").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    follow = db().table("hq_followups").select("id,suggested_date,note,status").eq("appointment_id", str(appointment_id)).limit(1).execute().data
    # raw doctor notes ("transcript") are never returned to the patient
    return {"appointment": appt, "summary": consult[0] if consult else None,
            "prescription": rx[0] if rx else None, "follow_up": follow[0] if follow else None}


@router.get("/prescriptions")
def list_prescriptions(actor: dict = Depends(patient_only)):
    return (db().table("hq_prescriptions").select(
        "id,items,advice,created_at,appointment:hq_appointments(id,appointment_date,queue_number,patient_name),"
        "doctor:hq_profiles!hq_prescriptions_doctor_id_fkey(full_name,specialty)")
        .eq("patient_id", actor["id"]).order("created_at", desc=True).execute().data)


@router.get("/prescriptions/{prescription_id}/pdf")
def prescription_pdf_download(prescription_id: UUID, actor: dict = Depends(patient_only)):
    rows = (db().table("hq_prescriptions").select(
        "*,appointment:hq_appointments(appointment_date,queue_number,patient_name,department:hq_departments(name)),"
        "doctor:hq_profiles!hq_prescriptions_doctor_id_fkey(full_name,specialty)")
        .eq("id", str(prescription_id)).eq("patient_id", actor["id"]).limit(1).execute().data)
    if not rows:
        raise HTTPException(status_code=404, detail="Prescription not found.")
    rx = rows[0]
    consult = db().table("hq_consultations").select("diagnosis").eq("appointment_id", rx["appointment_id"]).limit(1).execute().data
    appt, doctor = rx["appointment"], rx["doctor"]
    pdf = prescription_pdf(
        patient_name=appt["patient_name"], doctor_name=doctor["full_name"], specialty=doctor.get("specialty"),
        department=(appt.get("department") or {}).get("name"), visit_date=appt["appointment_date"],
        token=f"A-{appt['queue_number']}", items=rx["items"], advice=rx.get("advice"),
        diagnosis=consult[0]["diagnosis"] if consult else None)
    return Response(content=pdf, media_type="application/pdf", headers={
        "Content-Disposition": f'attachment; filename="prescription-{appt["appointment_date"]}.pdf"',
        "Cache-Control": "private, no-store"})


@router.get("/followups")
def list_followups(actor: dict = Depends(patient_only)):
    return (db().table("hq_followups").select(
        "id,suggested_date,note,status,doctor_id,dependent_id,doctor:hq_profiles!hq_followups_doctor_id_fkey(full_name,specialty)")
        .eq("patient_id", actor["id"]).eq("status", "open").gte("suggested_date", clinic_today().isoformat())
        .order("suggested_date").execute().data)


@router.post("/followups/{followup_id}/dismiss")
def dismiss_followup(followup_id: UUID, actor: dict = Depends(patient_only)):
    rows = db().table("hq_followups").update({"status": "dismissed"}).eq("id", str(followup_id)).eq("patient_id", actor["id"]).eq("status", "open").execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Follow-up not found.")
    return {"dismissed": True}


# ------------------------------------------------------ consent and photo ----
@router.get("/consents")
def my_consents(actor: dict = Depends(patient_only)):
    out = {}
    for kind in ("terms", "data_use", "photo"):
        out[kind] = has_consent(actor["id"], kind)
    return out


@router.put("/consents")
def update_consents(payload: ConsentUpdate, request: Request, actor: dict = Depends(patient_only)):
    """Terms and data use are required to hold an account; only the photo consent can be changed here."""
    db().table("hq_consents").insert({"patient_id": actor["id"], "kind": "photo", "granted": payload.photo, "recorded_by": actor["id"]}).execute()
    audit(actor, "consent.photo_updated", patient_id=actor["id"], details={"granted": payload.photo}, request=request)
    return {"photo": payload.photo}


@router.get("/identity-photo")
def my_photo_status(actor: dict = Depends(patient_only)):
    return photo_summary(get_photo(patient_id=actor["id"]))


@router.post("/identity-photo", status_code=status.HTTP_201_CREATED)
async def upload_my_photo(request: Request, image: UploadFile = File(...), actor: dict = Depends(patient_only)):
    if not has_consent(actor["id"], "photo"):
        raise HTTPException(status_code=403, detail="Turn on photo consent before uploading an identity photo.")
    raw = await image.read(MEDICAL_IMAGE_MAX_BYTES + 1)
    photo = store_photo(raw=raw, actor=actor, patient_id=actor["id"])
    audit(actor, "identity_photo.uploaded", target_type="identity_photo", target_id=photo["id"], patient_id=actor["id"], request=request)
    return photo_summary(photo)


# -------------------------------------------------------- medical records ----
@router.get("/medical-records")
def patient_medical_records(actor: dict = Depends(patient_only)):
    return db().table("hq_medical_records").select(
        "id,patient_id,appointment_id,record_type,title,original_filename,content_type,file_size_bytes,created_at"
    ).eq("patient_id", actor["id"]).order("created_at", desc=True).execute().data


@router.post("/medical-records", status_code=status.HTTP_201_CREATED)
async def upload_patient_medical_record(
    image: UploadFile = File(...),
    record_type: Literal["prescription", "report", "other"] = Form(...),
    title: str = Form(default="", max_length=160),
    appointment_id: UUID | None = Form(default=None),
    actor: dict = Depends(patient_only),
):
    if image.content_type not in {"image/jpeg", "image/png", "image/webp", "application/octet-stream"}:
        raise HTTPException(status_code=415, detail="Use a JPG, PNG, or WEBP image.")
    if appointment_id is not None:
        visits = db().table("hq_appointments").select("id,status").eq("id", str(appointment_id)).eq("patient_id", actor["id"]).limit(1).execute().data
        if not visits or visits[0]["status"] != "completed":
            raise HTTPException(status_code=409, detail="Attach records only to your completed visit.")
    raw = await image.read(MEDICAL_IMAGE_MAX_BYTES + 1)
    compressed = compress_medical_image(raw)
    record_id = str(uuid4())
    storage_path = f"{actor['id']}/{record_id}.jpg"
    client = db()
    try:
        client.storage.from_(MEDICAL_RECORDS_BUCKET).upload(storage_path, compressed, file_options={"content-type": "image/jpeg", "upsert": "false"})
        rows = client.table("hq_medical_records").insert({
            "id": record_id, "patient_id": actor["id"], "uploaded_by": actor["id"],
            "appointment_id": str(appointment_id) if appointment_id else None, "record_type": record_type,
            "title": title.strip() or ("Prescription" if record_type == "prescription" else "Medical report" if record_type == "report" else "Medical image"),
            "original_filename": (image.filename or "medical-image")[:200], "content_type": "image/jpeg",
            "file_size_bytes": len(compressed), "storage_path": storage_path}).execute().data
        return medical_record_metadata(rows[0])
    except HTTPException:
        raise
    except Exception as exc:
        try:
            client.storage.from_(MEDICAL_RECORDS_BUCKET).remove([storage_path])
        except Exception:
            pass
        raise HTTPException(status_code=502, detail="The medical image could not be saved. Please try again.") from exc


@router.get("/medical-records/{record_id}/image")
def patient_medical_record_image(record_id: UUID, actor: dict = Depends(patient_only)):
    rows = db().table("hq_medical_records").select("storage_path").eq("id", str(record_id)).eq("patient_id", actor["id"]).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Medical record not found.")
    try:
        data = db().storage.from_(MEDICAL_RECORDS_BUCKET).download(rows[0]["storage_path"])
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The medical image could not be loaded.") from exc
    return Response(content=data, media_type="image/jpeg", headers={"Cache-Control": "private, no-store"})


@router.delete("/medical-records/{record_id}")
def delete_patient_medical_record(record_id: UUID, actor: dict = Depends(patient_only)):
    rows = db().table("hq_medical_records").select("id,storage_path").eq("id", str(record_id)).eq("patient_id", actor["id"]).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Medical record not found.")
    try:
        db().storage.from_(MEDICAL_RECORDS_BUCKET).remove([rows[0]["storage_path"]])
        db().table("hq_medical_records").delete().eq("id", str(record_id)).eq("patient_id", actor["id"]).execute()
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The medical record could not be deleted.") from exc
    return {"deleted": True}
