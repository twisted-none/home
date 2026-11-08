import json
import os
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import event, select, text
from sqlalchemy.orm import sessionmaker

from app import chores, import_catalogs, worker
from app.db import Base, get_db, make_engine, now
from app.main import AuthLimit, app
from app.models import Delivery, Product


@pytest.fixture
def stack(tmp_path, monkeypatch):
    pg_url = os.getenv("TEST_DATABASE_URL")
    engine = make_engine(pg_url or f"sqlite:///{(tmp_path / 'test.sqlite3').as_posix()}")
    if pg_url:
        schema = f"test_{uuid4().hex}"
        with engine.begin() as connection:
            connection.execute(text(f"CREATE SCHEMA {schema}"))

        @event.listens_for(engine, "checkout")
        def test_schema(raw, _, __):
            with raw.cursor() as cursor:
                cursor.execute(f"SET search_path TO {schema}")
            raw.commit()

    Base.metadata.create_all(engine)
    sessions = sessionmaker(engine, expire_on_commit=False)

    def get_test_db():
        with sessions() as db:
            yield db

    app.dependency_overrides[get_db] = get_test_db
    app.state.auth_limit = AuthLimit()
    monkeypatch.setattr(worker, "Sessions", sessions)
    monkeypatch.setattr(import_catalogs, "Sessions", sessions)
    try:
        yield TestClient(app, base_url="http://testserver/api/v1/"), sessions
    finally:
        app.dependency_overrides.clear()
        if pg_url:
            with engine.begin() as connection:
                connection.execute(text(f"DROP SCHEMA {schema} CASCADE"))
        engine.dispose()


def register(client, name):
    response = client.post("auth/register", json={
        "name": name, "email": f"{name}@example.com", "password": "test password",
    })
    assert response.status_code == 201, response.text
    return {"Authorization": f"Bearer {response.json()['token']}"}


def household(client):
    first, second, outsider = [register(client, name) for name in ("first", "second", "outside")]
    assert client.post("family", headers=first, json={"name": "Дом", "city": "domodedovo"}).status_code == 201
    assert client.post("family", headers=outsider, json={"name": "Другая", "city": "moscow"}).status_code == 201
    invite = client.post("family/invites", headers=first).json()
    assert invite["link"] == f"familyboard://invite/{invite['code']}"
    assert client.post("family/join", headers=second, json={"code": invite["code"]}).status_code == 200
    another = register(client, "another")
    assert client.post("family/join", headers=another, json={"code": invite["code"]}).status_code == 404
    assert client.patch("family", headers=second, json={"city": "moscow"}).status_code == 403
    return first, second, outsider


def test_recurring_chore_reminder_and_activity(stack, monkeypatch):
    client, sessions = stack
    first, second, outsider = household(client)
    second_id = client.get("family", headers=second).json()["user_id"]
    fid = "a" * 22
    assert client.put("devices", headers=second, json={"installation_id": fid}).status_code == 204
    stamp = datetime(2026, 11, 8, 22, 20, tzinfo=UTC)
    monkeypatch.setattr(chores, "now", lambda: stamp)
    monkeypatch.setattr(worker, "now", lambda: stamp)
    schedule = {"title": "Поменять лоток", "interval_days": 3, "first_date": "2026-11-08",
                "reminder_time": "19:30", "assignee_id": second_id}
    response = client.post("chores", headers=first, json=schedule)
    assert response.status_code == 201, response.text
    chore = response.json()
    worker.schedule_reminders()
    worker.schedule_reminders()
    notice = client.get("notifications", headers=second).json()
    assert len(notice) == 1 and notice[0]["kind"] == "chore"
    assert client.get("notifications", headers=first).json() == []
    with sessions() as db:
        assert db.get(Delivery, (notice[0]["id"], fid)) is not None
    path = f"chores/{chore['id']}/complete"
    complete = {"occurrence": chore["occurrence"]}
    assert client.post(path, headers=outsider, json=complete).status_code == 404
    if os.getenv("TEST_DATABASE_URL"):
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(client.post, path, headers=member, json=complete)
                       for member in (second, second)]
            results = [future.result() for future in futures]
    else:
        results = [client.post(path, headers=second, json=complete) for _ in range(2)]
    assert all(result.status_code == 200 for result in results), [result.text for result in results]
    assert results[0].json() == results[1].json()
    assert datetime.fromisoformat(results[0].json()["due_at"]) == datetime(2026, 11, 12, 16, 30, tzinfo=UTC)
    assert client.put(f"chores/{chore['id']}", headers=first,
                      json={**schedule, "expected_occurrence": chore["occurrence"]}).status_code == 409
    expected = {"2026-11-09": [{"title": "Поменять лоток", "name": "second"}]}
    assert client.get("activity", headers=first).json()["days"] == expected
    assert client.get("activity", headers=outsider).json()["days"] == {}
    assert client.get("chores", headers=outsider).json() == []


def fixture_feed(directory, chain, city, price, stamp=None):
    filename = f"{chain}-{city}.json"
    store_key = "pilot-store" if chain == "krasnoe-beloe" else "city"
    path = directory / filename
    path.write_text(json.dumps({
        "chain": chain, "city": city, "store_key": store_key,
        "observed_at": (stamp or now()).isoformat(),
        "products": [{"id": "item", "name": "Молоко", "category": "Тест", "unit": "шт.", "price_kopecks": price}],
    }), encoding="utf-8")
    source = import_catalogs.Source(
        chain=chain, city=city, store_key=store_key, store_name="Тестовая точка" if store_key != "city" else None,
        source_url=import_catalogs.CHAINS[chain][1], feed=filename, partial=True,
    )
    return path, source


def test_catalog_coverage_and_shopping(stack, tmp_path, monkeypatch):
    client, sessions = stack
    first, second, outsider = household(client)
    fid = "b" * 22
    assert client.put("devices", headers=second, json={"installation_id": fid}).status_code == 204
    sources = [fixture_feed(tmp_path, chain, city, 1800)[1]
               for chain in import_catalogs.CHAINS for city in import_catalogs.CITIES]
    manifest = tmp_path / "sources.json"
    manifest.write_text(json.dumps([source.model_dump() for source in sources]), encoding="utf-8")
    monkeypatch.setenv("CATALOG_MANIFEST", str(manifest))
    assert import_catalogs.sync_catalogs()
    selected_catalogs = client.get("catalogs", headers=first).json()
    assert selected_catalogs["city"] == "domodedovo"
    catalogs = selected_catalogs["chains"]
    assert len(catalogs) == 7 and all(chain["catalogs"] for chain in catalogs)
    ids = []
    for chain in catalogs:
        catalog = chain["catalogs"][0]
        assert catalog["partial"] and not catalog["stale"]
        if chain["chain"] == "krasnoe-beloe":
            assert catalog["store_name"] == "Тестовая точка"
        path = f"catalogs/{catalog['id']}/products"
        assert client.get(path, headers=outsider).status_code == 404
        product = client.get(path, headers=first, params={"q": "Молоко"}).json()["products"][0]
        assert product["price_kopecks"] == 1800
        ids.append(product["id"])

    for product_id in ids[:2]:
        body = {"product_id": product_id, "request_id": str(uuid4()), "quantity_milliunits": 1000}
        for _ in range(2):
            assert client.post("shopping/draft", headers=first, json=body).status_code == 201
    assert len(client.get("shopping", headers=first).json()["draft"]) == 2
    assert client.get("shopping", headers=second).json() == {"items": [], "draft": []}
    body = {"request_id": str(uuid4())}
    if os.getenv("TEST_DATABASE_URL"):
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(client.post, "shopping/publish", headers=first, json=body)
                       for _ in range(2)]
            assert [future.result().json() for future in futures] == [{"count": 2}, {"count": 2}]
    else:
        assert [client.post("shopping/publish", headers=first, json=body).json()
                for _ in range(2)] == [{"count": 2}, {"count": 2}]
    items = client.get("shopping", headers=second).json()["items"]
    assert {item["chain"] for item in items} == {"pyaterochka", "perekrestok"}
    assert client.get("shopping", headers=outsider).json()["items"] == []
    path = f"shopping/items/{items[0]['id']}"
    assert client.patch(path, headers=outsider, json={"bought": True}).status_code == 404
    assert client.patch(path, headers=second, json={"bought": True}).status_code == 200
    assert sum(item["bought"] for item in client.get("shopping", headers=first).json()["items"]) == 1
    notices = client.get("notifications", headers=second).json()
    assert [notice["kind"] for notice in notices] == ["shopping"]
    assert client.get("notifications", headers=first).json() == []
    calls = []
    clock = now()

    def flaky_firebase(message):
        calls.append(message)
        if len(calls) == 1:
            raise worker.exceptions.UnavailableError("Simulated temporary failure")

    monkeypatch.setattr(worker.messaging, "send", flaky_firebase)
    monkeypatch.setattr(worker, "now", lambda: clock)
    assert worker.send_one()
    assert not worker.send_one()
    clock += timedelta(minutes=3)
    assert worker.send_one()
    assert not worker.send_one()
    assert [message.fid for message in calls] == [fid, fid]
    assert calls[-1].android.notification.tag == notices[0]["id"]
    with sessions() as db:
        assert db.get(Delivery, (notices[0]["id"], fid)).finished


def test_import_preserves_snapshot_on_failure(stack, tmp_path):
    client, sessions = stack
    first, _, _ = household(client)
    stamp = now() - timedelta(hours=1)
    path, source = fixture_feed(tmp_path, "pyaterochka", "domodedovo", 3600, stamp)
    assert import_catalogs.import_source(source, tmp_path)
    with sessions() as db:
        product_id = db.scalar(select(Product.id))
    body = {"product_id": product_id, "request_id": str(uuid4()), "quantity_milliunits": 1000}
    assert client.post("shopping/draft", headers=first, json=body).status_code == 201
    fixture_feed(tmp_path, "pyaterochka", "domodedovo", 3700)
    assert import_catalogs.import_source(source, tmp_path)
    path.write_text("invalid feed", encoding="utf-8")
    assert not import_catalogs.import_source(source, tmp_path)
    catalog = client.get("catalogs", headers=first).json()["chains"][0]["catalogs"][0]
    assert catalog["stale"]
    path = f"catalogs/{catalog['id']}/products"
    current = client.get(path, headers=first).json()["products"][0]
    assert current["price_kopecks"] == 3700 and current["id"] == product_id
    assert client.get("shopping", headers=first).json()["draft"][0]["price_kopecks"] == 3600
