"""MarPatients tenant directory API (owner-only admin; public read-only directory).

Does NOT connect to Oracle or store patient information. No production credentials in source.
"""
from __future__ import annotations

import base64
import binascii
from contextlib import asynccontextmanager
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import threading
import time
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Request, status
from pydantic import BaseModel, Field
from sqlalchemy import Boolean, Column, DateTime, String, create_engine, select, func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

DB_URL = os.environ.get('DATABASE_URL', 'sqlite:///./marpatients.db')
if DB_URL.startswith('postgres://'):
    DB_URL = DB_URL.replace('postgres://', 'postgresql+psycopg://', 1)
elif DB_URL.startswith('postgresql://'):
    DB_URL = DB_URL.replace('postgresql://', 'postgresql+psycopg://', 1)
engine = create_engine(DB_URL, pool_pre_ping=True, connect_args={'check_same_thread': False} if DB_URL.startswith('sqlite:') else {})
SessionLocal = sessionmaker(bind=engine, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class Tenant(Base):
    __tablename__ = 'marpatients_tenants'
    code = Column(String(32), primary_key=True)
    name = Column(String(250), nullable=False)
    medical = Column(Boolean, nullable=False, default=False)
    visible = Column(Boolean, nullable=False, default=False)
    active = Column(Boolean, nullable=False, default=False)
    updated_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


class AuditEvent(Base):
    __tablename__ = 'marpatients_admin_audit'
    id = Column(String(40), primary_key=True, default=lambda: secrets.token_hex(16))
    action = Column(String(50), nullable=False)
    tenant_code = Column(String(32), nullable=False)
    happened_at = Column(DateTime(timezone=True), nullable=False, default=lambda: datetime.now(timezone.utc))


def _seed_if_empty():
    with SessionLocal() as db:
        if db.scalar(select(func.count()).select_from(Tenant)):
            return
        seed_path = Path(__file__).parent / 'seed' / 'complexes.json'
        for c in json.loads(seed_path.read_text(encoding='utf-8')):
            db.add(Tenant(code=str(c['code']), name=c['name'], medical=bool(c['medical']), visible=False, active=False))
        db.commit()


@asynccontextmanager
async def lifespan(_: FastAPI):
    Base.metadata.create_all(bind=engine)
    _seed_if_empty()
    yield


app = FastAPI(title='MarPatients Tenant API', version='1.0', lifespan=lifespan,
              docs_url=None, redoc_url=None, openapi_url=None)


class OwnerLogin(BaseModel):
    username: str = Field(min_length=1, max_length=100)
    password: str = Field(min_length=1, max_length=256)


class TenantCreate(BaseModel):
    code: str = Field(min_length=1, max_length=32, pattern=r'^\d+$')
    name: str = Field(min_length=2, max_length=250)
    medical: bool = True
    visible: bool = False
    active: bool = False


class TenantPatch(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=250)
    medical: bool | None = None
    visible: bool | None = None
    active: bool | None = None


def _as_dict(t: Tenant):
    return {'code': t.code, 'name': t.name, 'medical': t.medical, 'visible': t.visible, 'active': t.active}


def _db():
    with SessionLocal() as db:
        yield db


# Small single-instance throttle for initial tests. Production needs an edge/global rate limit.
_login_attempts: dict[str, list[float]] = {}
_login_lock = threading.Lock()


def _rate_limit(key: str):
    now = time.monotonic()
    with _login_lock:
        recent = [t for t in _login_attempts.get(key, []) if now - t < 900]
        if len(recent) >= 5:
            raise HTTPException(status_code=429, detail='Try later')
        recent.append(now)
        _login_attempts[key] = recent


def _token_secret() -> bytes:
    secret = os.environ.get('TOKEN_SECRET', '')
    if len(secret) < 32:
        raise HTTPException(status_code=503, detail='Server admin authentication is not configured')
    return secret.encode('utf-8')


def _issue_token() -> str:
    payload = {'sub': 'owner', 'exp': int(time.time()) + 2 * 3600, 'nonce': secrets.token_hex(12)}
    data = base64.urlsafe_b64encode(json.dumps(payload, separators=(',', ':')).encode()).rstrip(b'=')
    signature = hmac.new(_token_secret(), data, hashlib.sha256).digest()
    return data.decode() + '.' + base64.urlsafe_b64encode(signature).rstrip(b'=').decode()


def _owner(authorization: Annotated[str | None, Header()] = None):
    if not authorization or not authorization.startswith('Bearer '):
        raise HTTPException(status_code=401, detail='Owner login required')
    try:
        data, sig = authorization.removeprefix('Bearer ').split('.', 1)
        expected = hmac.new(_token_secret(), data.encode(), hashlib.sha256).digest()
        given = base64.urlsafe_b64decode(sig + '=' * (-len(sig) % 4))
        payload = json.loads(base64.urlsafe_b64decode(data + '=' * (-len(data) % 4)))
        if not hmac.compare_digest(expected, given) or payload.get('sub') != 'owner' or payload.get('exp', 0) < time.time():
            raise ValueError('invalid token')
    except (ValueError, TypeError, KeyError, binascii.Error):
        raise HTTPException(status_code=401, detail='Invalid session') from None
    return 'owner'


@app.get('/health')
def health():
    return {'status': 'ok'}


@app.get('/v1/public/complexes')
def public_complexes(db: Session = Depends(_db)):
    # Only the directory is public; never return credentials, Oracle URLs, or patient data.
    rows = db.scalars(select(Tenant).where(Tenant.medical.is_(True), Tenant.visible.is_(True), Tenant.active.is_(True)).order_by(Tenant.name)).all()
    return [_as_dict(t) for t in rows]


@app.post('/v1/admin/login')
def owner_login(credentials: OwnerLogin, request: Request):
    owner_password = os.environ.get('OWNER_PASSWORD', '')
    if len(owner_password) < 12:
        raise HTTPException(status_code=503, detail='Owner account not configured')
    _token_secret()  # Fail closed if not configured.
    key = request.client.host if request.client else 'unknown'
    _rate_limit(key)
    owner_name = os.environ.get('OWNER_USERNAME', 'owner')
    if not (secrets.compare_digest(credentials.username, owner_name) and secrets.compare_digest(credentials.password, owner_password)):
        raise HTTPException(status_code=401, detail='Invalid credentials')
    with _login_lock:
        _login_attempts.pop(key, None)
    return {'access_token': _issue_token(), 'token_type': 'bearer', 'expires_in': 7200}


@app.get('/v1/admin/tenants', dependencies=[Depends(_owner)])
def admin_tenants(db: Session = Depends(_db)):
    rows = db.scalars(select(Tenant).order_by(Tenant.code)).all()
    return {'items': [_as_dict(t) for t in rows], 'count': len(rows)}


@app.post('/v1/admin/tenants', status_code=status.HTTP_201_CREATED, dependencies=[Depends(_owner)])
def create_tenant(body: TenantCreate, db: Session = Depends(_db)):
    code = body.code.strip()
    name = body.name.strip()
    if len(name) < 2:
        raise HTTPException(status_code=422, detail='Name required')
    row = Tenant(code=code, name=name, medical=body.medical, visible=body.visible, active=body.active)
    db.add(row)
    db.add(AuditEvent(action='create', tenant_code=code))
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        raise HTTPException(status_code=409, detail='Customer code already exists') from None
    return _as_dict(row)


@app.patch('/v1/admin/tenants/{code}', dependencies=[Depends(_owner)])
def patch_tenant(code: str, body: TenantPatch, db: Session = Depends(_db)):
    row = db.get(Tenant, code)
    if row is None:
        raise HTTPException(status_code=404, detail='Customer not found')
    updates = body.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(status_code=422, detail='No changes')
    for field, value in updates.items():
        if value is None:
            raise HTTPException(status_code=422, detail='Null not allowed')
        if field == 'name':
            value = value.strip()
            if len(value) < 2:
                raise HTTPException(status_code=422, detail='Name required')
        setattr(row, field, value)
    row.updated_at = datetime.now(timezone.utc)
    db.add(AuditEvent(action='update', tenant_code=code))
    db.commit()
    return _as_dict(row)
