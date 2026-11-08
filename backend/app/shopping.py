from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query, Response
from sqlalchemy import select

from .auth import DB, Identity
from .catalog_data import CHAINS, catalog_view
from .db import new_id
from .families import family_for, members
from .models import Catalog, Product, Publication, ShoppingItem
from .notices import enqueue
from .schemas import DraftInput, PublishInput, PurchasedInput

router = APIRouter()


def item_view(item: ShoppingItem) -> dict:
    return {
        "id": item.id, "name": item.name, "city": item.city, "chain": item.chain, "store_name": item.store_name,
        "unit": item.unit, "price_kopecks": item.price_kopecks, "quantity_milliunits": item.quantity_milliunits,
        "bought": item.bought,
    }


@router.get("/catalogs")
def list_catalogs(db: DB, identity: Identity):
    family = family_for(db, identity[0])
    catalogs = db.scalars(select(Catalog).where(Catalog.city == family.city).order_by(Catalog.store_name))
    by_chain: dict[str, list[dict]] = {chain: [] for chain in CHAINS}
    for catalog in catalogs:
        by_chain[catalog.chain].append(catalog_view(catalog))
    return {
        "city": family.city,
        "chains": [{"chain": chain, "name": name, "source_url": url, "catalogs": by_chain[chain]}
                   for chain, (name, url) in CHAINS.items()],
    }


@router.get("/catalogs/{catalog_id}/products")
def list_products(
    catalog_id: UUID, db: DB, identity: Identity, q: Annotated[str, Query(max_length=100)] = "",
    offset: Annotated[int, Query(ge=0)] = 0,
):
    family = family_for(db, identity[0])
    catalog = db.get(Catalog, str(catalog_id))
    if not catalog or catalog.city != family.city:
        raise HTTPException(404, "Каталог для выбранного города не найден")
    query = select(Product).where(Product.catalog_id == catalog.id)
    if q.strip():
        query = query.where(Product.name.icontains(q.strip(), autoescape=True))
    products = list(db.scalars(query.order_by(Product.name, Product.id).offset(offset).limit(51)))
    return {
        "catalog": catalog_view(catalog),
        "next_offset": offset + 50 if len(products) > 50 else None,
        "products": [{"id": product.id, "name": product.name, "category": product.category,
                      "unit": product.unit, "price_kopecks": product.price_kopecks, "source_url": product.source_url}
                     for product in products[:50]],
    }


@router.get("/shopping")
def shopping(db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user)
    items = list(db.scalars(select(ShoppingItem).where(
        ShoppingItem.family_id == family.id, ShoppingItem.published | (ShoppingItem.added_by == user.id)
    ).order_by(ShoppingItem.bought, ShoppingItem.added_at, ShoppingItem.id)))
    return {
        "items": [item_view(item) for item in items if item.published],
        "draft": [item_view(item) for item in items if not item.published],
    }


@router.post("/shopping/draft", status_code=201)
def add_to_draft(body: DraftInput, db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user, lock=True)
    existing = db.get(ShoppingItem, str(body.request_id))
    if existing:
        if existing.family_id != family.id or existing.added_by != user.id or existing.product_id != str(body.product_id):
            raise HTTPException(409, "Этот запрос уже использован")
        return item_view(existing)
    match = db.execute(select(Product, Catalog).join(Catalog, Catalog.id == Product.catalog_id)
                       .where(Product.id == str(body.product_id), Catalog.city == family.city)).one_or_none()
    if match is None:
        raise HTTPException(404, "Товар больше не доступен в этом каталоге")
    product, catalog = match
    item = ShoppingItem(
        id=str(body.request_id), family_id=family.id, added_by=user.id, product_id=product.id,
        city=catalog.city, chain=catalog.chain, store_name=catalog.store_name, name=product.name,
        unit=product.unit, price_kopecks=product.price_kopecks, quantity_milliunits=body.quantity_milliunits,
    )
    db.add(item)
    db.commit()
    return item_view(item)


@router.delete("/shopping/draft/{item_id}", status_code=204)
def remove_draft(item_id: UUID, db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user, lock=True)
    item = db.get(ShoppingItem, str(item_id))
    if item and item.family_id == family.id and item.added_by == user.id and not item.published:
        db.delete(item)
    db.commit()
    return Response(status_code=204)


@router.post("/shopping/publish")
def publish(body: PublishInput, db: DB, identity: Identity):
    user = identity[0]
    family = family_for(db, user, lock=True)
    key = (user.id, str(body.request_id))
    prior = db.get(Publication, key)
    if prior:
        return {"count": prior.count}
    draft = list(db.scalars(select(ShoppingItem).where(
        ShoppingItem.family_id == family.id, ShoppingItem.added_by == user.id, ~ShoppingItem.published
    )))
    if not draft:
        return {"count": 0}
    for item in draft:
        item.published = True
    publication = Publication(user_id=user.id, request_id=key[1], family_id=family.id, count=len(draft))
    db.add(publication)
    enqueue(db, family.id, [member.id for member in members(db, family.id) if member.id != user.id],
            "shopping", new_id())
    db.commit()
    return {"count": publication.count}


@router.patch("/shopping/items/{item_id}")
def mark_bought(item_id: UUID, body: PurchasedInput, db: DB, identity: Identity):
    family = family_for(db, identity[0], lock=True)
    item = db.get(ShoppingItem, str(item_id))
    if not item or item.family_id != family.id or not item.published:
        raise HTTPException(404, "Позиция не найдена")
    item.bought = body.bought
    db.commit()
    return item_view(item)
