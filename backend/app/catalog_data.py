from datetime import timedelta

from .db import as_utc, now
from .models import Catalog

CHAINS = {
    "pyaterochka": ("Пятёрочка", "https://5ka.ru/catalog/"),
    "perekrestok": ("Перекрёсток", "https://www.perekrestok.ru/cat"),
    "chizhik": ("Чижик", "https://chizhik.club/catalog/"),
    "dixy": ("Дикси", "https://dixy.ru/"),
    "magnit": ("Магнит", "https://magnit.ru/catalog"),
    "krasnoe-beloe": ("Красное&Белое", "https://krasnoeibeloe.ru/catalog/"),
    "aromatny-mir": ("Ароматный Мир", "https://amwine.ru/catalog/"),
}
CITIES = {"moscow": "Москва", "domodedovo": "Домодедово"}


def catalog_view(catalog: Catalog) -> dict:
    return {
        "id": catalog.id,
        "city": catalog.city,
        "store_name": catalog.store_name,
        "source_url": catalog.source_url,
        "partial": catalog.partial,
        "updated_at": as_utc(catalog.updated_at),
        "stale": catalog.failed_at is not None or as_utc(catalog.updated_at) < now() - timedelta(hours=48),
    }
