"""Identity photos: stored in a private bucket, locked once an authorised person confirms them."""
from uuid import UUID, uuid4

from fastapi import HTTPException

from .common import IDENTITY_BUCKET, compress_medical_image, db, utc_iso


def has_consent(patient_id: str, kind: str) -> bool:
    rows = (db().table("hq_consents").select("granted").eq("patient_id", patient_id).eq("kind", kind)
            .order("created_at", desc=True).limit(1).execute().data)
    return bool(rows and rows[0]["granted"])


def get_photo(*, patient_id: str | None = None, appointment_id: str | None = None) -> dict | None:
    query = db().table("hq_identity_photos").select("*")
    query = query.eq("patient_id", patient_id) if patient_id else query.eq("appointment_id", appointment_id)
    rows = query.limit(1).execute().data
    return rows[0] if rows else None


def photo_summary(photo: dict | None) -> dict:
    if not photo:
        return {"exists": False, "status": "none", "locked": False}
    return {"exists": True, "id": photo["id"], "status": photo["status"], "locked": photo["locked"],
            "confirmed_at": photo.get("confirmed_at")}


def store_photo(*, raw: bytes, actor: dict, patient_id: str | None = None, appointment_id: str | None = None) -> dict:
    existing = get_photo(patient_id=patient_id, appointment_id=appointment_id)
    if existing and existing["locked"]:
        raise HTTPException(status_code=409, detail="This photo is confirmed and locked. Ask an administrator to unlock it if it is wrong.")
    jpeg = compress_medical_image(raw, max_side=900)
    subject = patient_id or appointment_id
    path = f"{'p' if patient_id else 'a'}/{subject}/{uuid4()}.jpg"
    db().storage.from_(IDENTITY_BUCKET).upload(path, jpeg, file_options={"content-type": "image/jpeg", "upsert": "false"})
    try:
        if existing:
            row = db().table("hq_identity_photos").update({
                "storage_path": path, "status": "pending", "created_by": actor["id"],
                "confirmed_by": None, "confirmed_at": None}).eq("id", existing["id"]).execute().data[0]
            try:
                db().storage.from_(IDENTITY_BUCKET).remove([existing["storage_path"]])
            except Exception:
                pass
        else:
            row = db().table("hq_identity_photos").insert({
                "patient_id": patient_id, "appointment_id": appointment_id,
                "storage_path": path, "created_by": actor["id"]}).execute().data[0]
        return row
    except Exception as exc:
        try:
            db().storage.from_(IDENTITY_BUCKET).remove([path])
        except Exception:
            pass
        raise HTTPException(status_code=502, detail="The photo could not be saved. Please try again.") from exc


def confirm_photo(photo_id: UUID | str, actor: dict) -> dict:
    rows = db().table("hq_identity_photos").select("*").eq("id", str(photo_id)).limit(1).execute().data
    if not rows:
        raise HTTPException(status_code=404, detail="Photo not found.")
    photo = rows[0]
    if photo["locked"]:
        raise HTTPException(status_code=409, detail="This photo is already confirmed.")
    return db().table("hq_identity_photos").update({
        "status": "confirmed", "locked": True, "confirmed_by": actor["id"], "confirmed_at": utc_iso(),
    }).eq("id", photo["id"]).eq("locked", False).execute().data[0]


def photo_bytes(photo: dict) -> bytes:
    try:
        return db().storage.from_(IDENTITY_BUCKET).download(photo["storage_path"])
    except Exception as exc:
        raise HTTPException(status_code=502, detail="The photo could not be loaded.") from exc
