#!/usr/bin/env bash
#
# Guardian SOC paneli için Tailscale ve kimlik bilgilerini tek komutla hazırlar.
# Bu script root olarak veya sudo yetkili bir kullanıcıyla çalıştırılmalıdır.

set -u

readonly ENV_FILE="/etc/guardian/soc.env"
readonly SOC_SERVICE="guardian-soc.service"
readonly SOC_TARGET="http://127.0.0.1:8767"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

log() {
  printf '%b[INFO]%b %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
  printf '%b[UYARI]%b %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

die() {
  printf '%b[HATA]%b %s\n' "${RED}" "${RESET}" "$*" >&2
  exit 1
}

run_privileged() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

require_commands() {
  local command_name
  for command_name in awk chmod chown install mktemp python3 systemctl; do
    command -v "${command_name}" >/dev/null 2>&1 ||
      die "Gerekli komut bulunamadı: ${command_name}"
  done
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then
    log "Tailscale zaten kurulu."
  else
    log "Tailscale kuruluyor..."
    run_privileged apt-get update
    run_privileged apt-get install -y tailscale ||
      die "Tailscale kurulamadı. Ubuntu Tailscale deposunu kontrol edin."
  fi

  command -v tailscale >/dev/null 2>&1 ||
    die "Kurulumdan sonra tailscale komutu bulunamadı."

  run_privileged systemctl enable --now tailscaled ||
    die "tailscaled başlatılamadı."

  if [[ -n "$(tailscale ip -4 2>/dev/null || true)" ]]; then
    log "Tailscale zaten bağlı; tailscale up atlandı."
    return 0
  fi

  log "Tailscale bağlantısı başlatılıyor..."
  if ! run_privileged tailscale up --accept-dns=false; then
    die "Tailscale bağlantısı tamamlanmadı. Terminalde gösterilen giriş bağlantısını açın ve scripti tekrar çalıştırın."
  fi
}

ensure_soc_env() {
  local python_bin="${GUARDIAN_PYTHON:-/opt/guardian/venv/bin/python3}"
  local generated_file
  local generated_password
  local generated_hash
  local generated_totp
  local generated_secret
  local generated_jwt
  local generated_username
  local env_existed=0

  if [[ ! -x "${python_bin}" ]]; then
    python_bin="$(command -v python3)"
  fi
  [[ -x "${python_bin}" ]] ||
    die "Python 3 bulunamadı."

  if [[ -f "${ENV_FILE}" ]]; then
    env_existed=1
  fi

  generated_file="$(mktemp)"
  chmod 600 "${generated_file}"
  if ! "${python_bin}" - "${ENV_FILE}" > "${generated_file}" <<'PY'
import os
import secrets
import sys

env_path = sys.argv[1]
try:
    import bcrypt
    import pyotp
except ImportError as exc:
    print(f"Python bağımlılığı eksik: {exc}", file=sys.stderr)
    raise SystemExit(2)

values = {
    "SECRET_KEY": secrets.token_hex(32),
    "JWT_SECRET_KEY": secrets.token_hex(32),
    "GUARDIAN_SOC_USERNAME": "guardian",
}
password = ""
totp_secret = ""

if os.path.exists(env_path):
    with open(env_path, encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key in values:
                values[key] = value
            elif key == "GUARDIAN_SOC_PASSWORD_BCRYPT":
                values[key] = value
            elif key == "GUARDIAN_SOC_TOTP_SECRET":
                values[key] = value

if not values.get("GUARDIAN_SOC_PASSWORD_BCRYPT"):
    password = secrets.token_urlsafe(16)
    values["GUARDIAN_SOC_PASSWORD_BCRYPT"] = bcrypt.hashpw(
        password.encode("utf-8"), bcrypt.gensalt()
    ).decode("ascii")

if not values.get("GUARDIAN_SOC_TOTP_SECRET"):
    totp_secret = pyotp.random_base32()
    values["GUARDIAN_SOC_TOTP_SECRET"] = totp_secret

print("GUARDIAN_SOC_PASSWORD_PLAINTEXT=" + password)
print("GUARDIAN_SOC_TOTP_PLAINTEXT=" + totp_secret)
for key in (
    "SECRET_KEY",
    "JWT_SECRET_KEY",
    "GUARDIAN_SOC_USERNAME",
    "GUARDIAN_SOC_PASSWORD_BCRYPT",
    "GUARDIAN_SOC_TOTP_SECRET",
):
    print(f"{key}={values[key]}")
PY
  then
    rm -f "${generated_file}"
    die "SOC kimlik bilgileri üretilemedi. bcrypt ve pyotp paketlerini venv'e kurun."
  fi

  generated_password="$(awk -F= '$1 == "GUARDIAN_SOC_PASSWORD_PLAINTEXT" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  generated_totp="$(awk -F= '$1 == "GUARDIAN_SOC_TOTP_PLAINTEXT" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  generated_hash="$(awk -F= '$1 == "GUARDIAN_SOC_PASSWORD_BCRYPT" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  generated_secret="$(awk -F= '$1 == "SECRET_KEY" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  generated_jwt="$(awk -F= '$1 == "JWT_SECRET_KEY" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  generated_username="$(awk -F= '$1 == "GUARDIAN_SOC_USERNAME" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"

  [[ -n "${generated_hash}" && -n "${generated_secret}" && -n "${generated_jwt}" &&
    -n "${generated_username}" ]] ||
    die "Üretilen SOC ortam değerleri eksik."

  run_privileged install -d -m 0750 -o root -g guardian /etc/guardian
  local output_file
  output_file="$(mktemp)"
  chmod 600 "${output_file}"
  {
    printf 'SECRET_KEY=%s\n' "${generated_secret}"
    printf 'JWT_SECRET_KEY=%s\n' "${generated_jwt}"
    printf 'GUARDIAN_SOC_USERNAME=%s\n' "${generated_username}"
    printf 'GUARDIAN_SOC_PASSWORD_BCRYPT=%s\n' "${generated_hash}"
    printf 'GUARDIAN_SOC_TOTP_SECRET=%s\n' "$(awk -F= '$1 == "GUARDIAN_SOC_TOTP_SECRET" {print substr($0, index($0, "=") + 1)}' "${generated_file}")"
  } > "${output_file}"
  run_privileged install -m 0640 -o root -g guardian "${output_file}" "${ENV_FILE}"
  rm -f "${output_file}" "${generated_file}"

  if [[ -n "${generated_password}" || -n "${generated_totp}" ]]; then
    printf '\n%b========== YENİ SOC KİMLİK BİLGİLERİ ==========%b\n' "${YELLOW}" "${RESET}"
    printf 'Kullanıcı adı: %s\n' "${generated_username}"
    [[ -n "${generated_password}" ]] && printf 'Şifre: %s\n' "${generated_password}"
    [[ -n "${generated_totp}" ]] && printf '2FA secret: %s\n' "${generated_totp}"
    printf 'Bu bilgileri güvenli bir parola yöneticisine ve Authenticator uygulamasına kaydedin.\n'
    printf '%b===============================================%b\n\n' "${YELLOW}" "${RESET}"
  elif [[ "${env_existed}" -eq 1 ]]; then
    warn "Mevcut SOC kimlik bilgileri korundu; düz metin şifre yeniden gösterilemez."
  fi
}

start_soc_and_serve() {
  run_privileged systemctl restart "${SOC_SERVICE}" ||
    die "${SOC_SERVICE} yeniden başlatılamadı. journalctl -u ${SOC_SERVICE} ile inceleyin."
  run_privileged tailscale serve --bg "${SOC_TARGET}" ||
    die "Tailscale Serve yapılandırılamadı."
}

print_connection_info() {
  local tailscale_ip
  tailscale_ip="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
  [[ -n "${tailscale_ip}" ]] || die "Tailscale IPv4 adresi alınamadı."

  printf '\n%b╔══════════════════════════════════════════════╗%b\n' "${GREEN}" "${RESET}"
  printf '%b║          GUARDIAN SOC PANEL HAZIR           ║%b\n' "${GREEN}" "${RESET}"
  printf '%b╠══════════════════════════════════════════════╣%b\n' "${GREEN}" "${RESET}"
  printf '║ Telefon tarayıcısından açın:                 ║\n'
  printf '║ http://%s:8767/login\n' "${tailscale_ip}"
  printf '║                                              ║\n'
  printf '║ Tailscale HTTPS adresi:                      ║\n'
  printf '║ https://%s/login\n' "${tailscale_ip}"
  printf '%b╚══════════════════════════════════════════════╝%b\n\n' "${GREEN}" "${RESET}"
}

main() {
  [[ "${EUID}" -eq 0 ]] || command -v sudo >/dev/null 2>&1 ||
    die "Script root veya sudo yetkisiyle çalıştırılmalıdır."
  require_commands
  install_tailscale
  ensure_soc_env
  start_soc_and_serve
  print_connection_info
}

main "$@"
