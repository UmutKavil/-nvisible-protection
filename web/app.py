"""Guardian SOC giriş uygulaması."""

from __future__ import annotations

from datetime import timedelta

from flask import Flask, redirect, render_template, request, url_for
from flask_limiter import Limiter
from flask_wtf import CSRFProtect
from werkzeug.exceptions import TooManyRequests

from auth import (
    JWT_COOKIE,
    configure_auth,
    enforce_ip_allowlist,
    limiter,
    login_required,
    login_user,
)

app = Flask(__name__, template_folder="../templates")
configure_auth(app)
app.config["PERMANENT_SESSION_LIFETIME"] = timedelta(hours=1)
csrf = CSRFProtect(app)


@app.before_request
def restrict_panel_network() -> None:
    enforce_ip_allowlist()


@app.after_request
def add_security_headers(response):
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; style-src 'self' 'unsafe-inline'; "
        "script-src 'self'; img-src 'self' data:; frame-ancestors 'none'"
    )
    return response


@app.errorhandler(TooManyRequests)
def handle_rate_limit(error):
    return "Çok fazla deneme. Lütfen 15 dakika sonra tekrar deneyin.", 429


@app.route("/login", methods=["GET", "POST"])
@limiter.limit("5 per 5 minutes", methods=["POST"])
def login():
    next_path = request.args.get("next", "/")
    if request.method == "POST":
        token = login_user(
            request.form.get("username", ""),
            request.form.get("password", ""),
            request.form.get("totp_code", ""),
        )
        if token:
            safe_next = (
                next_path
                if next_path.startswith("/") and not next_path.startswith("//")
                else "/"
            )
            response = redirect(safe_next)
            response.set_cookie(
                JWT_COOKIE,
                token,
                max_age=3600,
                secure=True,
                httponly=True,
                samesite="Lax",
                path="/",
            )
            return response
        return render_template(
            "login.html",
            error="Kullanıcı adı veya şifre hatalı.",
        ), 401
    return render_template("login.html", error=None)


@app.post("/logout")
def logout():
    response = redirect(url_for("login"))
    response.delete_cookie(JWT_COOKIE, path="/")
    return response


@app.get("/")
@login_required
def dashboard():
    return "Guardian SOC paneli - dashboard tasarımı sonraki aşamada."


if __name__ == "__main__":
    # 8766 mevcut guardian-web API'sidir; SOC login için 8767 kullanılır.
    app.run(host="0.0.0.0", port=8767, debug=False, use_reloader=False)
