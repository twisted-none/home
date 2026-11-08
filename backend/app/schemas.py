from datetime import date, time
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, StringConstraints, field_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
City = Literal["moscow", "domodedovo"]


class Credentials(BaseModel):
    email: Annotated[EmailStr, Field(max_length=254)]
    password: Annotated[str, Field(min_length=8, max_length=128)]


class Registration(Credentials):
    name: Name


class NewFamily(BaseModel):
    name: Name
    city: City


class ChangeCity(BaseModel):
    city: City


class JoinFamily(BaseModel):
    code: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{43}$")]


class ChoreInput(BaseModel):
    title: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    interval_days: Annotated[int, Field(ge=1, le=365)]
    first_date: date
    reminder_time: time
    assignee_id: UUID | None = None

    @field_validator("first_date")
    @classmethod
    def valid_date(cls, value: date) -> date:
        if not date(2000, 1, 1) <= value <= date(2100, 12, 31):
            raise ValueError("Дата вне допустимого диапазона")
        return value

    @field_validator("reminder_time")
    @classmethod
    def local_minutes(cls, value: time) -> time:
        if value.tzinfo is not None or value.second or value.microsecond:
            raise ValueError("Укажите местное время в часах и минутах")
        return value


class CompletionInput(BaseModel):
    occurrence: UUID


class ChoreUpdate(ChoreInput):
    expected_occurrence: UUID


class DraftInput(BaseModel):
    product_id: UUID
    request_id: UUID
    quantity_milliunits: Annotated[int, Field(ge=1, le=999_000)]


class PublishInput(BaseModel):
    request_id: UUID


class PurchasedInput(BaseModel):
    bought: bool


class DeviceInput(BaseModel):
    installation_id: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{22}$")]
    previous_installation_id: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{22}$")] | None = None
