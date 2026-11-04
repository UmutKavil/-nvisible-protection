#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG="/opt/guardian/config/guardian.conf"
readonly COMPOSE="/opt/guardian/docker/docker-compose.yml"

enabled="$(awk -F= '$1 == "HONEYPOT_ENABLED" {print $2}' "${CONFIG}" 2>/dev/null || true)"
if [[ "${enabled}" != "1" ]]; then
  if /usr/bin/docker inspect invisible-dionaea >/dev/null 2>&1; then
    /usr/bin/docker compose -f "${COMPOSE}" down
  fi
  exit 0
fi

exec /usr/bin/docker compose -f "${COMPOSE}" up -d
