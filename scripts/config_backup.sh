#!/usr/bin/env bash
set -Eeuo pipefail

# Config deposu yalnızca yapılandırmayı içerir; olay, veri ve loglar dahil edilmez.
readonly CONFIG_DIR="${GUARDIAN_CONFIG_DIR:-/opt/guardian/config}"
readonly BACKUP_DIR="${GUARDIAN_BACKUP_DIR:-/opt/guardian/backups}"
readonly GIT_NAME="guardian"
readonly GIT_EMAIL="guardian@localhost"

[[ -d "${CONFIG_DIR}" ]] || { printf 'Config dizini yok: %s\n' "${CONFIG_DIR}" >&2; exit 1; }
command -v git >/dev/null || { printf 'git kurulu değil.\n' >&2; exit 1; }
git -C "${CONFIG_DIR}" init -q
git -C "${CONFIG_DIR}" config user.name "${GIT_NAME}"
git -C "${CONFIG_DIR}" config user.email "${GIT_EMAIL}"
git -C "${CONFIG_DIR}" add --all
if ! git -C "${CONFIG_DIR}" diff --cached --quiet; then
  git -C "${CONFIG_DIR}" commit -q -m "Config snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi

# Günlük timer çalışır; arşiv yalnızca Pazar günü alınır ve dört haftadan eskiler silinir.
if [[ "$(date +%u)" == "7" ]]; then
  mkdir -p "${BACKUP_DIR}"
  archive="${BACKUP_DIR}/config-$(date +%F).tar.gz"
  tar -C "${CONFIG_DIR}" --exclude=.git -czf "${archive}" .
  find "${BACKUP_DIR}" -type f -name 'config-*.tar.gz' -mtime +28 -delete
fi
