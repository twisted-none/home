import secrets
from datetime import timedelta

from argon2.exceptions import VerifyMismatchError
from fastapi import APIRouter, HTTPException, Request, Response
from sqlalchemy import delete, select
from sqlalchemy.exc import IntegrityError

from .auth import DB, Identity, create_session, digest, dummy_hash, lock_session, passwords
from .db import as_utc, now
from .models import Device, Family, Invite, User
from .schemas import ChangeCity, Credentials, JoinFamily, NewFamily, Registration

router = APIRouter()


def guard_auth(request: Request, email: str) -> None:
    request.app.state.auth_limit.check(email.lower())


@router.post("/auth/register", status_code=201)
def register(body: Registration, db: DB, request: Request):
    guard_auth(request, body.email)
    user = User(email=body.email.lower(), name=body.name, password=passwords.hash(body.password))
    db.add(user)
    try:
        db.flush()
        return create_session(db, user)
    except IntegrityError as exc:
        raise HTTPException(409, "Не удалось зарегистрировать этот email") from exc


@router.post("/auth/login")
def login(body: Credentials, db: DB, request: Request):
    guard_auth(request, body.email)
    user = db.scalar(select(User).where(User.email == body.email.lower()))
    try:
        passwords.verify(user.password if user else dummy_hash, body.password)
    except VerifyMismatchError as exc:
        raise HTTPException(401, "Неверный email или пароль") from exc
    if user is None:
        raise HTTPException(401, "Неверный email или пароль")
    if passwords.check_needs_rehash(user.password):
        user.password = passwords.hash(body.password)
    return create_session(db, user)


@router.post("/auth/logout", status_code=204)
def logout(db: DB, identity: Identity):
    session = lock_session(db, identity[1])
    db.execute(delete(Device).where(Device.session_digest == session.digest))
    db.delete(session)
    db.commit()
    return Response(status_code=204)


def family_for(db: DB, user: User, *, lock: bool = False) -> Family:
    query = select(Family).where(Family.id == user.family_id)
    family = db.scalar(query.with_for_update() if lock else query)
    if family is None:
        raise HTTPException(403, "Сначала вступите в семью")
    return family


def members(db: DB, family_id: str) -> list[User]:
    return list(db.scalars(select(User).where(User.family_id == family_id).order_by(User.name, User.id)))


def family_view(db: DB, user: User) -> dict:
    result = {"user_id": user.id, "name": user.name, "owner": user.owner, "family": None, "members": []}
    if user.family_id:
        family = db.get(Family, user.family_id)
        result["family"] = {"id": family.id, "name": family.name, "city": family.city, "timezone": family.timezone}
        result["members"] = [{"id": member.id, "name": member.name} for member in members(db, family.id)]
    return result


def lock_unassigned_user(db: DB, user: User) -> None:
    db.refresh(user, with_for_update=True)
    if user.family_id is not None:
        raise HTTPException(409, "Вы уже состоите в семье")


@router.get("/family")
def get_family(db: DB, identity: Identity):
    return family_view(db, identity[0])


@router.post("/family", status_code=201)
def create_family(body: NewFamily, db: DB, identity: Identity):
    user = identity[0]
    lock_unassigned_user(db, user)
    family = Family(name=body.name, city=body.city)
    db.add(family)
    db.flush()
    user.family_id = family.id
    user.owner = True
    db.commit()
    return family_view(db, user)


@router.patch("/family")
def update_city(body: ChangeCity, db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user, lock=True)
    if not user.owner:
        raise HTTPException(403, "Город может изменить создатель семьи")
    family.city = body.city
    db.commit()
    return family_view(db, user)


@router.post("/family/invites", status_code=201)
def invite_member(db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user)
    if not user.owner:
        raise HTTPException(403, "Приглашения создаёт создатель семьи")
    code = secrets.token_urlsafe(32)
    expires = now() + timedelta(days=1)
    db.add(Invite(digest=digest(code), family_id=family.id, expires_at=expires))
    db.commit()
    return {"code": code, "link": f"familyboard://invite/{code}", "expires_at": expires}


@router.post("/family/join")
def join_family(body: JoinFamily, db: DB, identity: Identity):
    user = identity[0]
    lock_unassigned_user(db, user)
    invite = db.scalar(select(Invite).where(Invite.digest == digest(body.code)).with_for_update())
    if invite is None or invite.used_at or as_utc(invite.expires_at) <= now():
        raise HTTPException(404, "Приглашение недействительно или уже использовано")
    invite.used_at = now()
    user.family_id = invite.family_id
    db.commit()
    return family_view(db, user)
