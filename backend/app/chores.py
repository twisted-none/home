from calendar import monthrange
from datetime import UTC, date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from fastapi import APIRouter, HTTPException, Response
from sqlalchemy import select

from .auth import DB, Identity
from .db import as_utc, new_id, now
from .families import family_for
from .models import Chore, Completion, Family, User
from .schemas import ChoreInput, ChoreUpdate, CompletionInput

router = APIRouter()


def chore_view(chore: Chore) -> dict:
    return {
        "id": chore.id, "title": chore.title, "interval_days": chore.interval_days,
        "assignee_id": chore.assignee_id, "reminder_time": chore.local_time.isoformat(timespec="minutes"),
        "due_at": as_utc(chore.due_at), "occurrence": chore.occurrence,
    }


def find_chore(db: DB, family: Family, chore_id: UUID, *, lock: bool = False) -> Chore:
    query = select(Chore).where(Chore.id == str(chore_id), Chore.family_id == family.id)
    chore = db.scalar(query.with_for_update() if lock else query)
    if chore is None:
        raise HTTPException(404, "Дело не найдено")
    return chore


def assign(db: DB, family: Family, chore: Chore, body: ChoreInput) -> None:
    assignee = str(body.assignee_id) if body.assignee_id else None
    if assignee and db.scalar(select(User.id).where(User.id == assignee, User.family_id == family.id)) is None:
        raise HTTPException(422, "Исполнитель должен состоять в вашей семье")
    chore.title = body.title
    chore.interval_days = body.interval_days
    chore.assignee_id = assignee
    chore.local_time = body.reminder_time
    chore.due_at = datetime.combine(body.first_date, body.reminder_time, ZoneInfo(family.timezone)).astimezone(UTC)


@router.get("/chores")
def list_chores(db: DB, identity: Identity):
    family = family_for(db, identity[0])
    chores = db.scalars(select(Chore).where(Chore.family_id == family.id, ~Chore.archived).order_by(Chore.due_at))
    return [chore_view(chore) for chore in chores]


@router.post("/chores", status_code=201)
def add_chore(body: ChoreInput, db: DB, identity: Identity):
    family = family_for(db, identity[0])
    chore = Chore(family_id=family.id)
    assign(db, family, chore, body)
    db.add(chore)
    db.commit()
    return chore_view(chore)


@router.put("/chores/{chore_id}")
def update_chore(chore_id: UUID, body: ChoreUpdate, db: DB, identity: Identity):
    family = family_for(db, identity[0])
    chore = find_chore(db, family, chore_id, lock=True)
    if chore.archived:
        raise HTTPException(404, "Дело не найдено")
    if chore.occurrence != str(body.expected_occurrence):
        raise HTTPException(409, "Дело уже изменилось. Обновите список")
    old_due, old_assignee = as_utc(chore.due_at), chore.assignee_id
    assign(db, family, chore, body)
    if (old_due, old_assignee) != (chore.due_at, chore.assignee_id):
        chore.occurrence = new_id()
        chore.reminded = False
    db.commit()
    return chore_view(chore)


@router.delete("/chores/{chore_id}", status_code=204)
def archive_chore(chore_id: UUID, db: DB, identity: Identity):
    family = family_for(db, identity[0])
    chore = find_chore(db, family, chore_id, lock=True)
    chore.archived = True
    db.commit()
    return Response(status_code=204)


@router.post("/chores/{chore_id}/complete")
def complete(chore_id: UUID, body: CompletionInput, db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user)
    chore = find_chore(db, family, chore_id, lock=True)
    occurrence = str(body.occurrence)
    existing = db.get(Completion, occurrence)
    if existing is not None and existing.chore_id == chore.id:
        return chore_view(chore)
    if chore.archived or chore.occurrence != occurrence:
        raise HTTPException(409, "Дело уже изменилось. Обновите список")
    completed_at = now()
    zone = ZoneInfo(family.timezone)
    day = completed_at.astimezone(zone).date()
    db.add(Completion(occurrence=occurrence, family_id=family.id, chore_id=chore.id,
                      user_id=user.id, title=chore.title, local_date=day, done_at=completed_at))
    chore.due_at = datetime.combine(day + timedelta(days=chore.interval_days), chore.local_time, zone).astimezone(UTC)
    chore.occurrence = new_id()
    chore.reminded = False
    db.commit()
    return chore_view(chore)


def first_history_day(today: date) -> date:
    last_year = today.year - 1
    day = min(today.day, monthrange(last_year, today.month)[1])
    return date(last_year, today.month, day) + timedelta(days=1)


@router.get("/activity")
def activity(db: DB, identity: Identity):
    family = family_for(db, identity[0])
    today = now().astimezone(ZoneInfo(family.timezone)).date()
    start = first_history_day(today)
    rows = db.execute(
        select(Completion, User.name).join(User, User.id == Completion.user_id)
        .where(Completion.family_id == family.id, Completion.local_date.between(start, today))
        .order_by(Completion.done_at)
    )
    days = {}
    for completion, name in rows:
        days.setdefault(completion.local_date.isoformat(), []).append({"title": completion.title, "name": name})
    return {"start": start, "today": today, "days": days}
