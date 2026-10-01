#!/usr/bin/env bash
set -Eeuo pipefail
LOG_DIR="/opt/guardian/logs/active"
ARCHIVE_DIR="${LOG_DIR}/archive"
mkdir -p "${ARCHIVE_DIR}"
find "${LOG_DIR}" -maxdepth 1 -type f -name '*.jsonl' -size +0c -print0 |
  while IFS= read -r -d '' file; do
    base="$(basename "${file}")"
    pigz -c "${file}" > "${ARCHIVE_DIR}/${base}.$(date +%F).gz"
    : > "${file}"
  done
find "${ARCHIVE_DIR}" -type f -name '*.gz' -mtime +30 -delete
