#!/usr/bin/env bash
set -Eeuo pipefail

readonly CONFIG="/opt/guardian/config/guardian.conf"
readonly DIONAEA_COMPOSE="/opt/guardian/docker/docker-compose.yml"
readonly COWRIE_COMPOSE="/opt/guardian/docker/cowrie/docker-compose.yml"

enabled="$(awk -F= '$1 == "HONEYPOT_ENABLED" {print $2}' "${CONFIG}" 2>/dev/null || true)"
honeypot_type="$(awk -F= '$1 == "HONEYPOT_TYPE" {print $2}' "${CONFIG}" 2>/dev/null || true)"
if [[ "${enabled}" != "1" ]]; then
  /usr/bin/docker compose -f "${DIONAEA_COMPOSE}" down 2>/dev/null || true
  /usr/bin/docker compose -f "${COWRIE_COMPOSE}" down 2>/dev/null || true
  exit 0
fi

case "${honeypot_type}" in
  dionaea)
    /usr/bin/docker compose -f "${COWRIE_COMPOSE}" down
    exec /usr/bin/docker compose -f "${DIONAEA_COMPOSE}" up -d
    ;;
  cowrie)
    /usr/bin/docker compose -f "${DIONAEA_COMPOSE}" down
    exec /usr/bin/docker compose -f "${COWRIE_COMPOSE}" up -d
    ;;
  *)
    printf 'Geçersiz HONEYPOT_TYPE: %s (dionaea veya cowrie olmalı)\n' "${honeypot_type}" >&2
    exit 1
    ;;
esac
