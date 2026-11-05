"""Guardian SOC kimlik doğrulama yardımcıları."""

from __future__ import annotations

import ipaddress
import os
import threading
import time
from functools import wraps
from typing import Any, Callable

import bcrypt
import jwt
import pyotp
from flask import Flask, abort, redirect, request, url_for
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.exceptions import TooManyRequests

JWT_COOKIE = "guardian_soc_token"
JWT_ALGORITHM = "HS256"
JWT_TTL_SECONDS = 3600
MAX_FAILED_ATTEMPTS = 5
BAN_SECONDS = 15 * 60

limiter = Limiter(
    key_func=get_remote_address,
    default_limits=[],
    storage_uri=os.environ.get("GUARDIAN_LIMITER_STORAGE", "memory://"),
)
_failed_attempts: dict[str, tuple[int, float]] = {}
_attempts_lock = threading.Lock()


def _client_ip() -> str:
    """Proxy başlıklarına güvenmeden doğrudan bağlantı adresini kullanır."""
    return request.remote_addr or "unknown"


def is_allowed_ip(address: str) -> bool:
    """Paneli localhost ve Tailscale CGNAT aralığıyla sınırlar."""
    try:
        client_ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    return client_ip.is_loopback or client_ip in ipaddress.ip_network("100.64.0.0/10")


def enforce_ip_allowlist() -> None:
    if not is_allowed_ip(_client_ip()):
        abort(403)


def _is_banned(address: str) -> bool:
    with _attempts_lock:
        attempt_data = _failed_attempts.get(address)
        if not attempt_data:
            return False
        _, banned_until = attempt_data
        if banned_until > time.monotonic():
            return True
        _failed_attempts.pop(address, None)
        return False


def record_failed_login(address: str) -> None:
    with _attempts_lock:
        attempts, banned_until = _failed_attempts.get(address, (0, 0.0))
        attempts += 1
        if attempts >= MAX_FAILED_ATTEMPTS:
            attempts = 0
            banned_until = time.monotonic() + BAN_SECONDS
        _failed_attempts[address] = (attempts, banned_until)


def clear_failed_logins(address: str) -> None:
    with _attempts_lock:
        _failed_attempts.pop(address, None)


def _credentials_valid(username: str, password: str, totp_code: str) -> bool:
    """Şifre ve TOTP'yi backend'de doğrular; ayrıntılı hata ifşa etmez."""
    expected_user = os.environ.get("GUARDIAN_SOC_USERNAME", "")
    password_hash = os.environ.get("GUARDIAN_SOC_PASSWORD_BCRYPT", "").encode("ascii")
    totp_secret = os.environ.get("GUARDIAN_SOC_TOTP_SECRET", "")
    if not expected_user or not password_hash or not totp_secret:
        return False
    if len(totp_code) != 6 or not totp_code.isdigit():
        return False
    try:
        password_ok = username == expected_user and bcrypt.checkpw(
            password.encode("utf-8"), password_hash
        )
        totp_ok = pyotp.TOTP(totp_secret).verify(totp_code, valid_window=1)
    except (ValueError, TypeError, UnicodeError):
        return False
    return password_ok and totp_ok


def create_jwt(username: str) -> str:
    secret = os.environ.get("JWT_SECRET_KEY", "")
    if not secret:
        raise RuntimeError("JWT_SECRET_KEY tanımlı değil")
    now = int(time.time())
    return jwt.encode(
        {"sub": username, "iat": now, "exp": now + JWT_TTL_SECONDS},
        secret,
        algorithm=JWT_ALGORITHM,
    )


def _decode_jwt(token: str) -> dict[str, Any] | None:
    secret = os.environ.get("JWT_SECRET_KEY", "")
    if not secret:
        return None
    try:
        payload = jwt.decode(token, secret, algorithms=[JWT_ALGORITHM])
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None
    return payload if isinstance(payload, dict) else None


def login_required(function: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(function)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        enforce_ip_allowlist()
        payload = _decode_jwt(request.cookies.get(JWT_COOKIE, ""))
        if not payload or not payload.get("sub"):
            return redirect(url_for("login", next=request.path))
        return function(*args, **kwargs)

    return wrapper


def configure_auth(app: Flask) -> None:
    secret_key = os.environ.get("SECRET_KEY", "")
    if not secret_key:
        raise RuntimeError("SECRET_KEY tanımlı değil")
    app.secret_key = secret_key
    app.config.update(
        SESSION_COOKIE_SECURE=True,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
    )
    limiter.init_app(app)


def login_user(username: str, password: str, totp_code: str) -> str | None:
    address = _client_ip()
    if _is_banned(address):
        raise TooManyRequests(description="Geçici olarak çok fazla başarısız deneme yapıldı.")
    if not _credentials_valid(username, password, totp_code):
        record_failed_login(address)
        return None
    clear_failed_logins(address)
    return create_jwt(username)
