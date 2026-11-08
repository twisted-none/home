from sqlalchemy import select
from sqlalchemy.orm import Session

from .db import now
from .models import Delivery, Device, LoginSession, Notice


def enqueue(db: Session, family_id: str, user_ids: list[str], kind: str, subject_id: str) -> None:
    if not user_ids:
        return
    notices = {
        user_id: Notice(user_id=user_id, family_id=family_id, kind=kind, subject_id=subject_id)
        for user_id in user_ids
    }
    db.add_all(notices.values())
    db.flush()
    devices = db.execute(
        select(Device.installation_id, LoginSession.user_id)
        .join(LoginSession, LoginSession.digest == Device.session_digest)
        .where(LoginSession.user_id.in_(user_ids), LoginSession.expires_at > now())
    )
    db.add_all(Delivery(notice_id=notices[user_id].id, installation_id=fid) for fid, user_id in devices)
