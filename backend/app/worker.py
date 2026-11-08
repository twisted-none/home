import logging
import os
from datetime import timedelta
from threading import Thread
from time import sleep

import firebase_admin
from firebase_admin import exceptions, messaging
from google.auth.exceptions import GoogleAuthError
from sqlalchemy import delete, select

from .db import Sessions, as_utc, now
from .import_catalogs import sync_catalogs
from .models import Chore, Delivery, Device, LoginSession, Notice, User
from .notices import enqueue

logger = logging.getLogger(__name__)


def schedule_reminders() -> None:
    with Sessions.begin() as db:
        chores = db.scalars(select(Chore).where(~Chore.archived, ~Chore.reminded, Chore.due_at <= now())
                            .order_by(Chore.due_at).limit(50).with_for_update(skip_locked=True))
        for chore in chores:
            recipients = select(User.id).where(User.family_id == chore.family_id)
            if chore.assignee_id:
                recipients = recipients.where(User.id == chore.assignee_id)
            enqueue(db, chore.family_id, list(db.scalars(recipients)), "chore", chore.occurrence)
            chore.reminded = True


def send_one() -> bool:
    with Sessions.begin() as db:
        job = db.scalar(select(Delivery).where(~Delivery.finished, Delivery.next_at <= now())
                        .order_by(Delivery.next_at).limit(1).with_for_update(skip_locked=True))
        if not job:
            return False
        notice = db.get(Notice, job.notice_id)
        expires = as_utc(notice.created_at) + timedelta(hours=12)
        attempted_at = now()
        if expires <= attempted_at:
            job.finished = True
            return True
        device = db.get(Device, job.installation_id)
        session = db.get(LoginSession, device.session_digest) if device else None
        if not session or session.user_id != notice.user_id or as_utc(session.expires_at) <= now():
            job.finished = True
            return True
        if notice.kind == "chore" and not db.scalar(
            select(Chore.id).where(Chore.family_id == notice.family_id,
                                   Chore.occurrence == notice.subject_id, ~Chore.archived)
        ):
            job.finished = True
            return True
        body = "Пора выполнить домашнее дело" if notice.kind == "chore" else "Семья обновила список покупок"
        try:
            messaging.send(messaging.Message(
                fid=job.installation_id,
                notification=messaging.Notification(title="Домашние дела и покупки", body=body),
                data={"kind": notice.kind, "notice_id": notice.id},
                android=messaging.AndroidConfig(
                    priority="high", ttl=expires - attempted_at,
                    notification=messaging.AndroidNotification(tag=notice.id),
                ),
            ))
            job.finished = True
        except messaging.UnregisteredError:
            db.execute(delete(Device).where(Device.installation_id == job.installation_id,
                                            Device.session_digest == session.digest))
            job.finished = True
        except (exceptions.FirebaseError, GoogleAuthError, ValueError) as exc:
            job.attempts += 1
            job.finished = job.attempts >= 8 or expires <= now()
            job.next_at = now() + timedelta(minutes=min(2**job.attempts, 60))
            logger.warning("Push attempt %d failed for notice %s (%s)",
                           job.attempts, notice.id, type(exc).__name__)
        return True


def catalog_loop() -> None:
    while True:
        try:
            sync_catalogs()
        except Exception:
            logger.error("Catalog sync failed unexpectedly")
        sleep(3600)


def main() -> None:
    logging.basicConfig(level=logging.INFO)
    firebase_enabled = bool(os.getenv("GOOGLE_APPLICATION_CREDENTIALS"))
    if firebase_enabled:
        firebase_admin.initialize_app(options={"httpTimeout": 10})
    else:
        logger.info("Firebase disabled, in-app notifications remain enabled")
    Thread(target=catalog_loop, daemon=True).start()
    while True:
        try:
            schedule_reminders()
            if firebase_enabled:
                for _ in range(20):
                    if not send_one():
                        break
        except Exception:
            logger.error("Worker cycle failed")
        sleep(10)


if __name__ == "__main__":
    main()
