from __future__ import annotations

import hmac
import os
from functools import wraps
from typing import Any, Callable

from flask import Flask, Response, jsonify, request

from repository import EventRepository

app = Flask(__name__)
REPOSITORY = EventRepository(os.environ.get("GUARDIAN_EVENT_DB", "/opt/guardian/data/events.db"))
TOKEN = os.environ.get("GUARDIAN_API_TOKEN", "")


def require_token(function: Callable[..., Any]) -> Callable[..., Any]:
    @wraps(function)
    def wrapper(*args: Any, **kwargs: Any) -> Any:
        supplied = request.headers.get("Authorization", "")
        scheme, _, _ = supplied.partition(" ")
        expected = "Bearer " + TOKEN if TOKEN else ""
        if scheme.lower() != "bearer" or not TOKEN or not hmac.compare_digest(
            supplied, expected
        ):
            return jsonify({"error": "unauthorized"}), 401
        return function(*args, **kwargs)

    return wrapper


@app.get("/health")
def health() -> Any:
    return jsonify({"status": "ok"})


@app.get("/events")
@app.get("/api/events")
@require_token
def events() -> Any:
    return jsonify(
        REPOSITORY.list_events(
            limit=request.args.get("limit", 100, type=int),
            offset=request.args.get("offset", 0, type=int),
            severity=request.args.get("severity"),
        )
    )


@app.get("/stats")
@app.get("/api/stats")
@require_token
def stats() -> Any:
    return jsonify(REPOSITORY.stats())


@app.get("/api/events.csv")
@require_token
def events_csv() -> Response:
    return Response(
        REPOSITORY.csv_export(),
        mimetype="text/csv",
        headers={"Content-Disposition": "attachment; filename=guardian-events.csv"},
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8766, threaded=False, debug=False, use_reloader=False)
