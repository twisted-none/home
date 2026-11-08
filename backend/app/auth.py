import hashlib
import secrets
from datetime import timedelta
from typing import Annotated

from argon2 import PasswordHasher
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.orm import Session

from .db import as_utc, get_db, now
from .models import LoginSession, User

passwords = PasswordHasher()
dummy_hash = passwords.hash(secrets.token_urlsafe(32))
bearer = HTTPBearer(auto_error=False)
DB = Annotated[Session, Depends(get_db)]


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def create_session(db: Session, user: User) -> dict:
    token = secrets.token_urlsafe(32)
    db.add(LoginSession(digest=digest(token), user_id=user.id, expires_at=now() + timedelta(days=30)))
    db.commit()
    return {"token": token, "name": user.name}


def get_identity(
    db: DB, credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]
) -> tuple[User, LoginSession]:
    if credentials and len(credentials.credentials) == 43:
        session = db.get(LoginSession, digest(credentials.credentials))
        if session and as_utc(session.expires_at) > now():
            return db.get(User, session.user_id), session
    raise HTTPException(401, "Войдите в аккаунт", headers={"WWW-Authenticate": "Bearer"})


def lock_session(db: Session, session: LoginSession) -> LoginSession:
    locked = db.scalar(select(LoginSession).where(LoginSession.digest == session.digest)
                       .execution_options(populate_existing=True).with_for_update())
    if locked is None or as_utc(locked.expires_at) <= now():
        raise HTTPException(401, "Войдите в аккаунт", headers={"WWW-Authenticate": "Bearer"})
    return locked


Identity = Annotated[tuple[User, LoginSession], Depends(get_identity)]
