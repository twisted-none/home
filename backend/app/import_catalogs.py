import json
import logging
import os
from datetime import timedelta
from pathlib import Path
from typing import Annotated
from urllib.parse import urlsplit

import httpx
from pydantic import AwareDatetime, BaseModel, Field, StringConstraints, field_validator, model_validator
from sqlalchemy import select

from .catalog_data import CHAINS, CITIES
from .db import Sessions, as_utc, now
from .models import Catalog, Product

logger = logging.getLogger(__name__)
MAX_FEED_BYTES = 32 * 1024 * 1024
Text = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1)]
SourceUrl = Annotated[str, StringConstraints(min_length=1, max_length=2048)]


def https_url(value: str) -> str:
    url = urlsplit(value)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise ValueError("Expected an HTTPS URL without credentials or fragment")
    return value


class Source(BaseModel):
    chain: str
    city: str
    store_key: Annotated[Text, Field(max_length=120)] = "city"
    store_name: Annotated[Text, Field(max_length=200)] | None = None
    source_url: SourceUrl
    feed: Annotated[Text, Field(max_length=2048)]
    partial: bool

    @model_validator(mode="after")
    def check_scope(self):
        if self.chain not in CHAINS or self.city not in CITIES:
            raise ValueError("Unknown chain or city")
        if (self.store_key != "city") != bool(self.store_name):
            raise ValueError("A store needs both a unique key and a name")
        if self.chain == "krasnoe-beloe" and self.store_key == "city":
            raise ValueError("Красное&Белое needs a store-specific source")
        host = urlsplit(https_url(self.source_url)).hostname
        official = urlsplit(CHAINS[self.chain][1]).hostname.removeprefix("www.")
        if host != official and not host.endswith("." + official):
            raise ValueError("Source URL must point to the retailer's domain")
        if "://" in self.feed:
            https_url(self.feed)
        elif Path(self.feed).is_absolute() or ".." in Path(self.feed).parts:
            raise ValueError("Use a feed path relative to the manifest")
        return self


class FeedProduct(BaseModel):
    id: Annotated[Text, Field(max_length=200)]
    name: Annotated[Text, Field(max_length=200)]
    category: Annotated[Text, Field(max_length=100)]
    unit: Annotated[Text, Field(max_length=40)]
    price_kopecks: Annotated[int, Field(strict=True, ge=1, le=100_000_000)]
    source_url: SourceUrl | None = None

    @field_validator("source_url")
    @classmethod
    def check_url(cls, value: str | None):
        return https_url(value) if value is not None else None


class Feed(BaseModel):
    chain: str
    city: str
    store_key: str = "city"
    observed_at: AwareDatetime
    products: Annotated[list[FeedProduct], Field(min_length=1, max_length=50_000)]


def read_feed(source: Source, directory: Path) -> Feed:
    if source.feed.startswith("https://"):
        with httpx.stream("GET", source.feed, timeout=15, follow_redirects=False) as response:
            response.raise_for_status()
            data = bytearray()
            for chunk in response.iter_bytes(chunk_size=65_536):
                data.extend(chunk)
                if len(data) > MAX_FEED_BYTES:
                    raise ValueError("Feed is too large")
    else:
        target = (directory / source.feed).resolve()
        if not target.is_relative_to(directory.resolve()):
            raise ValueError("Feed must stay inside the manifest directory")
        with target.open("rb") as file:
            data = file.read(MAX_FEED_BYTES + 1)
        if len(data) > MAX_FEED_BYTES:
            raise ValueError("Feed is too large")
    feed = Feed.model_validate_json(data)
    if (feed.chain, feed.city, feed.store_key) != (source.chain, source.city, source.store_key):
        raise ValueError("Feed chain, city or store doesn't match the manifest")
    if len({product.id for product in feed.products}) != len(feed.products):
        raise ValueError("Duplicate product IDs")
    if feed.observed_at > now() + timedelta(minutes=10):
        raise ValueError("Observation time is in the future")
    official = urlsplit(CHAINS[source.chain][1]).hostname.removeprefix("www.")
    for product in feed.products:
        if product.source_url:
            host = urlsplit(product.source_url).hostname
            if host != official and not host.endswith("." + official):
                raise ValueError("Product source URL must point to the retailer's domain")
    return feed


def find_catalog(db, source: Source):
    return db.scalar(select(Catalog).where(Catalog.chain == source.chain,
                     Catalog.city == source.city, Catalog.store_key == source.store_key).with_for_update())


def import_source(source: Source, directory: Path) -> bool:
    try:
        feed = read_feed(source, directory)
        with Sessions.begin() as db:
            catalog = find_catalog(db, source)
            if not catalog:
                catalog = Catalog(chain=source.chain, city=source.city, store_key=source.store_key)
                db.add(catalog)
            elif as_utc(catalog.updated_at) > feed.observed_at:
                raise ValueError("Feed is older than the last imported snapshot")
            catalog.store_name = source.store_name
            catalog.source_url = source.source_url
            catalog.partial = source.partial
            catalog.updated_at = feed.observed_at
            catalog.failed_at = None
            db.flush()
            previous = {p.external_id: p for p in db.scalars(
                select(Product).where(Product.catalog_id == catalog.id))}
            for entry in feed.products:
                product = previous.pop(entry.id, None)
                if product is None:
                    product = Product(catalog_id=catalog.id, external_id=entry.id)
                    db.add(product)
                product.name = entry.name
                product.category = entry.category
                product.unit = entry.unit
                product.price_kopecks = entry.price_kopecks
                product.source_url = entry.source_url
            for product in previous.values():
                db.delete(product)
    except Exception as exc:
        # Validation errors may contain provider data or credentials embedded in URLs.
        logger.warning("Catalog failed: %s / %s / %s (%s)",
                       source.chain, source.city, source.store_key, type(exc).__name__)
        with Sessions.begin() as db:
            if catalog := find_catalog(db, source):
                catalog.failed_at = now()
        return False
    logger.info("Catalog imported: %s / %s / %s (%d products)",
                source.chain, source.city, source.store_key, len(feed.products))
    return feed.observed_at >= now() - timedelta(hours=48)


def sync_catalogs() -> bool:
    manifest = Path(os.getenv("CATALOG_MANIFEST", "catalog-config/sources.json"))
    if not manifest.is_file():
        logger.info("No catalog manifest configured")
        return False
    try:
        data = json.loads(manifest.read_text(encoding="utf-8"))
        sources = [Source.model_validate(item) for item in data]
        if len({(source.chain, source.city, source.store_key) for source in sources}) != len(sources):
            raise ValueError("Duplicate catalog sources")
    except (OSError, ValueError, TypeError) as exc:
        logger.error("Invalid catalog manifest (%s)", type(exc).__name__)
        return False
    imported = [import_source(source, manifest.parent) for source in sources]
    coverage = {(source.chain, source.city) for source, ok in zip(sources, imported) if ok}
    missing = {(chain, city) for chain in CHAINS for city in CITIES} - coverage
    if missing:
        logger.warning("Missing successful catalog import: %s", ", ".join(f"{c}/{g}" for c, g in sorted(missing)))
    return bool(imported) and all(imported) and not missing


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    raise SystemExit(0 if sync_catalogs() else 1)
