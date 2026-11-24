"""SMS fallback: messages are queued in hq_sms_outbox and sent through Twilio when configured."""
import logging
from datetime import datetime, timezone

import httpx

from .common import db, settings

log = logging.getLogger("queuecare.sms")


def flush_sms_outbox(limit: int = 20) -> int:
    if not (settings.twilio_account_sid and settings.twilio_auth_token and settings.twilio_from_number):
        return 0  # not configured: messages stay queued rather than being lost
    rows = db().table("hq_sms_outbox").select("*").eq("status", "pending").order("created_at").limit(limit).execute().data
    sent = 0
    for row in rows:
        try:
            response = httpx.post(
                f"https://api.twilio.com/2010-04-01/Accounts/{settings.twilio_account_sid}/Messages.json",
                auth=(settings.twilio_account_sid, settings.twilio_auth_token),
                data={"To": row["phone"], "From": settings.twilio_from_number, "Body": row["body"]}, timeout=10)
            response.raise_for_status()
            db().table("hq_sms_outbox").update({
                "status": "sent", "attempts": row["attempts"] + 1,
                "sent_at": datetime.now(timezone.utc).isoformat()}).eq("id", row["id"]).execute()
            sent += 1
        except Exception as exc:
            attempts = row["attempts"] + 1
            db().table("hq_sms_outbox").update({
                "status": "failed" if attempts >= 3 else "pending", "attempts": attempts,
                "last_error": str(exc)[:200]}).eq("id", row["id"]).execute()
    return sent


def post_queue_change(doctor_id: str, day) -> None:
    """Background task after the queue moves: 'N patients ahead' alerts, then deliver queued SMS."""
    from .common import send_queue_alerts
    try:
        send_queue_alerts(doctor_id, day)
        flush_sms_outbox()
    except Exception:
        log.exception("post queue change failed")
