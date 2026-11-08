import os
from collections.abc import Iterator
from datetime import UTC, datetime
from urllib.parse import quote_plus
from uuid import uuid4

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker


class Base(DeclarativeBase):
    pass


def make_engine(url: str):
    engine = create_engine(url, pool_pre_ping=True)
    if engine.dialect.name == "sqlite":
        @event.listens_for(engine, "connect")
        def enable_foreign_keys(connection, _):
            connection.execute("PRAGMA foreign_keys=ON")
    return engine


def now() -> datetime:
    return datetime.now(UTC)


def as_utc(value: datetime) -> datetime:
    return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)


def new_id() -> str:
    return str(uuid4())


def get_database_url() -> str:
    if url := os.getenv("DATABASE_URL"):
        return url
    if host := os.getenv("POSTGRES_HOST"):
        password = quote_plus(os.environ["POSTGRES_PASSWORD"])
        return f"postgresql+psycopg://family:{password}@{host}/family"
    return "sqlite:///./family.sqlite3"


database_url = get_database_url()
engine = make_engine(database_url)
Sessions = sessionmaker(engine, expire_on_commit=False)


def get_db() -> Iterator[Session]:
    with Sessions() as db:
        yield db
