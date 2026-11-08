from collections import OrderedDict, deque
from threading import Lock
from time import monotonic
from uuid import UUID

from fastapi import APIRouter, FastAPI, HTTPException, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy import delete, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert

from . import chores, families, shopping
from .auth import DB, Identity, lock_session
from .db import as_utc, now
from .models import Device, Notice
from .schemas import DeviceInput


class AuthLimit:
    """Bound password hashing per account and across this API process."""

    def __init__(self):
        self.lock = Lock()
        self.recent = deque()
        self.accounts = OrderedDict()

    def check(self, email: str) -> None:
        with self.lock:
            cutoff = monotonic() - 60
            while self.recent and self.recent[0] <= cutoff:
                self.recent.popleft()
            while self.accounts and next(iter(self.accounts.values()))[-1] <= cutoff:
                self.accounts.popitem(last=False)
            account = self.accounts.get(email, deque())
            while account and account[0] <= cutoff:
                account.popleft()
            if len(account) >= 10 or len(self.recent) >= 60:
                raise HTTPException(429, "Слишком много попыток. Попробуйте через минуту",
                                    headers={"Retry-After": "60"})
            timestamp = monotonic()
            account.append(timestamp)
            self.accounts[email] = account
            self.accounts.move_to_end(email)
            self.recent.append(timestamp)


app = FastAPI(title="Домашние дела и покупки", version="1.0.0")
app.state.auth_limit = AuthLimit()
api = APIRouter(prefix="/api/v1")
api.include_router(families.router)
api.include_router(chores.router)
api.include_router(shopping.router)


@app.exception_handler(RequestValidationError)
async def validation_error(_request: Request, _error: RequestValidationError):
    return JSONResponse(status_code=422, content={"detail": "Проверьте введённые данные"})


@app.get("/health")
def health(db: DB):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}


@api.get("/notifications")
def notifications(db: DB, identity: Identity):
    user = identity[0]
    notices = db.scalars(select(Notice).where(Notice.user_id == user.id, Notice.family_id == user.family_id)
                         .order_by(Notice.created_at.desc()).limit(100))
    return [{"id": notice.id, "kind": notice.kind, "created_at": as_utc(notice.created_at),
             "read": notice.read_at is not None} for notice in notices]


@api.post("/notifications/{notice_id}/read", status_code=204)
def read_notification(notice_id: UUID, db: DB, identity: Identity):
    user = identity[0]
    notice = db.get(Notice, str(notice_id))
    if not notice or notice.user_id != user.id or notice.family_id != user.family_id:
        raise HTTPException(404, "Уведомление не найдено")
    notice.read_at = notice.read_at or now()
    db.commit()
    return Response(status_code=204)


@api.put("/devices", status_code=204)
def register_device(body: DeviceInput, db: DB, identity: Identity):
    session = lock_session(db, identity[1])
    insert = pg_insert if db.bind.dialect.name == "postgresql" else sqlite_insert
    statement = insert(Device).values(installation_id=body.installation_id, session_digest=session.digest)
    db.execute(statement.on_conflict_do_update(index_elements=[Device.installation_id],
                                               set_={"session_digest": session.digest}))
    if body.previous_installation_id and body.previous_installation_id != body.installation_id:
        db.execute(delete(Device).where(Device.installation_id == body.previous_installation_id,
                                        Device.session_digest == session.digest))
    db.commit()
    return Response(status_code=204)


app.include_router(api)
