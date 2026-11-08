from datetime import date, datetime, time

from sqlalchemy import Date, DateTime, ForeignKey, Index, JSON, String, Time, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base, new_id, now


class Family(Base):
    __tablename__ = "families"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    name: Mapped[str] = mapped_column(String(80))
    city: Mapped[str] = mapped_column(String(30))
    timezone: Mapped[str] = mapped_column(String(64), default="Europe/Moscow")


class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(254), unique=True)
    name: Mapped[str] = mapped_column(String(80))
    password: Mapped[str] = mapped_column(String(255))
    family_id: Mapped[str | None] = mapped_column(ForeignKey("families.id"), index=True)
    owner: Mapped[bool] = mapped_column(default=False)


class LoginSession(Base):
    __tablename__ = "login_sessions"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), index=True)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Invite(Base):
    __tablename__ = "invites"
    digest: Mapped[str] = mapped_column(String(64), primary_key=True)
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class Chore(Base):
    __tablename__ = "chores"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    title: Mapped[str] = mapped_column(String(120))
    interval_days: Mapped[int]
    local_time: Mapped[time] = mapped_column(Time())
    assignee_id: Mapped[str | None] = mapped_column(ForeignKey("users.id"))
    due_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    occurrence: Mapped[str] = mapped_column(String(36), default=new_id)
    reminded: Mapped[bool] = mapped_column(default=False)
    archived: Mapped[bool] = mapped_column(default=False)
    __table_args__ = (Index("ix_chores_family_due", "family_id", "archived", "due_at"),
                      Index("ix_chores_reminder", "archived", "reminded", "due_at"))


class Completion(Base):
    __tablename__ = "completions"
    occurrence: Mapped[str] = mapped_column(String(36), primary_key=True)
    chore_id: Mapped[str] = mapped_column(ForeignKey("chores.id"))
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    title: Mapped[str] = mapped_column(String(120))
    local_date: Mapped[date] = mapped_column(Date())
    done_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    __table_args__ = (Index("ix_completions_family_date", "family_id", "local_date"),)


class Catalog(Base):
    __tablename__ = "catalogs"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    chain: Mapped[str] = mapped_column(String(30))
    city: Mapped[str] = mapped_column(String(30))
    store_key: Mapped[str] = mapped_column(String(120))
    store_name: Mapped[str | None] = mapped_column(String(200))
    source_url: Mapped[str] = mapped_column(String(2048))
    partial: Mapped[bool]
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    failed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    __table_args__ = (UniqueConstraint("chain", "city", "store_key"),)


class Product(Base):
    __tablename__ = "products"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    catalog_id: Mapped[str] = mapped_column(ForeignKey("catalogs.id"))
    external_id: Mapped[str] = mapped_column(String(200))
    name: Mapped[str] = mapped_column(String(200))
    category: Mapped[str] = mapped_column(String(100))
    unit: Mapped[str] = mapped_column(String(40))
    price_kopecks: Mapped[int]
    source_url: Mapped[str | None] = mapped_column(String(2048))
    __table_args__ = (UniqueConstraint("catalog_id", "external_id"),)


class ShoppingItem(Base):
    __tablename__ = "shopping_items"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    added_by: Mapped[str] = mapped_column(ForeignKey("users.id"))
    product_id: Mapped[str] = mapped_column(String(36))
    name: Mapped[str] = mapped_column(String(200))
    city: Mapped[str] = mapped_column(String(30))
    chain: Mapped[str] = mapped_column(String(30))
    store_name: Mapped[str | None] = mapped_column(String(200))
    unit: Mapped[str] = mapped_column(String(40))
    price_kopecks: Mapped[int]
    quantity_milliunits: Mapped[int]
    published: Mapped[bool] = mapped_column(default=False)
    bought: Mapped[bool] = mapped_column(default=False)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    __table_args__ = (Index("ix_items_family_published", "family_id", "published"),)


class Publication(Base):
    __tablename__ = "publications"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"), primary_key=True)
    request_id: Mapped[str] = mapped_column(String(36), primary_key=True)
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    count: Mapped[int]


class Notice(Base):
    __tablename__ = "notices"
    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id"))
    family_id: Mapped[str] = mapped_column(ForeignKey("families.id"))
    kind: Mapped[str] = mapped_column(String(20))
    subject_id: Mapped[str] = mapped_column(String(36))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    __table_args__ = (UniqueConstraint("user_id", "kind", "subject_id"),
                      Index("ix_notices_user_created", "user_id", "created_at"))


class Device(Base):
    __tablename__ = "devices"
    installation_id: Mapped[str] = mapped_column(String(22), primary_key=True)
    session_digest: Mapped[str] = mapped_column(ForeignKey("login_sessions.digest"), index=True)


class Delivery(Base):
    __tablename__ = "deliveries"
    notice_id: Mapped[str] = mapped_column(ForeignKey("notices.id"), primary_key=True)
    installation_id: Mapped[str] = mapped_column(String(22), primary_key=True)
    attempts: Mapped[int] = mapped_column(default=0)
    next_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=now)
    finished: Mapped[bool] = mapped_column(default=False)
    __table_args__ = (Index("ix_delivery_queue", "finished", "next_at"),)
