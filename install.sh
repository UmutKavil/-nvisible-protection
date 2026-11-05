#!/usr/bin/env bash
set -Euo pipefail
umask 022

readonly APP_ROOT="/opt/guardian"
readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SERVICE_USER="guardian"
readonly CONFIG_DIR="${APP_ROOT}/config"
readonly LOG_DIR="${APP_ROOT}/logs"
readonly ACTIVE_LOG_DIR="${LOG_DIR}/active"
readonly ARCHIVE_LOG_DIR="${LOG_DIR}/archive"
readonly SAMPLE_DIR="${APP_ROOT}/malware_samples"
readonly SWAPFILE="/swapfile"
readonly ORIGINAL_HOSTNAME="$(hostname)"
SSH_LOGIN_USER=""

readonly GREEN='\033[32m'
readonly RED='\033[31m'
readonly YELLOW='\033[33m'
readonly RESET='\033[0m'

log() { printf '[guardian-install] %s\n' "$*"; }
warn() { printf '[guardian-install][WARN] %s\n' "$*" >&2; }
ok() { printf '%b[BAŞARILI]%b %s\n' "${GREEN}" "${RESET}" "$*"; }
skip() { printf '%b[ATLANDI]%b %s\n' "${YELLOW}" "${RESET}" "$*"; }
step_error() { printf '%b[HATA]%b %s\n' "${RED}" "${RESET}" "$*" >&2; }
die() { step_error "$*"; return 1; }
on_error() {
  local exit_code=$?
  printf '%b[HATA]%b Kurulum adımı başarısız oldu (satır %s, çıkış kodu %s).\n' \
    "${RED}" "${RESET}" \
    "${BASH_LINENO[0]}" "${exit_code}" >&2
  printf '[guardian-install] Başarısız komut: %s\n' "${BASH_COMMAND}" >&2
  return "${exit_code}"
}
trap on_error ERR

if [[ "${EUID}" -ne 0 ]]; then
  step_error "Root yetkisi gerekli: sudo ./install.sh"
  exit 1
fi
# shellcheck disable=SC1091
if [[ -r /etc/os-release ]]; then
  source /etc/os-release
else
  ID=""
  VERSION_ID=""
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

readonly PACKAGES=(
  build-essential pigz htop iotop git curl wget jq zram-tools watchdog irqbalance
  network-manager avahi-daemon avahi-utils iproute2 iptables
  iw libpcap-dev tcpdump tshark fail2ban docker.io file openssl
  libpam-google-authenticator auditd audispd-plugins
  ethtool sysstat cpufrequtils lm-sensors stress-ng nftables log2ram
  docker-compose-v2 qemu-user-static binfmt-support python3-pip python3-venv
  python3-full openssh-server unattended-upgrades
)

run_step() {
  local name="$1" function_name="$2"
  printf '\n%b[ADIM]%b %s\n' "${YELLOW}" "${RESET}" "${name}"
  if "${function_name}"; then
    ok "${name}"
  else
    step_error "${name} başarısız oldu; sonraki adıma geçiliyor."
  fi
}

ensure_line() {
  local line="$1" file="$2"
  grep -qxF "${line}" "${file}" 2>/dev/null || printf '%s\n' "${line}" >> "${file}"
}

preflight_checks() {
  log "Kurulum ön koşulları kontrol ediliyor..."
  local free_kb ram_kb
  free_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
  [[ "${free_kb}" =~ ^[0-9]+$ && "${free_kb}" -ge 8388608 ]] ||
    die "Kök dosya sisteminde en az 8 GB boş alan gerekir. Çözüm: df -h ile alanı kontrol edin."
  ram_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  [[ "${ram_kb}" =~ ^[0-9]+$ && "${ram_kb}" -ge 3145728 ]] ||
    die "En az 3 GB RAM gerekir. 4 GB veya 8 GB Pi 5 modeli kullanın."
  command -v systemctl >/dev/null ||
    die "systemctl bulunamadı; systemd tabanlı Ubuntu Server kullanın."
  command -v apt-get >/dev/null ||
    die "apt-get bulunamadı; desteklenen Ubuntu Server kurulumu kullanın."
  getent hosts archive.ubuntu.com >/dev/null ||
    die "Ubuntu paket deposu çözümlenemiyor. Ağ bağlantısı ve DNS ayarlarını kontrol edin."
  getent hosts registry-1.docker.io >/dev/null ||
    die "Docker Hub çözümlenemiyor. Ağ bağlantısı ve DNS ayarlarını kontrol edin."
  if command -v fuser >/dev/null && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    die "Başka bir apt/dpkg işlemi çalışıyor. İşlem bitince kurulumu yeniden başlatın."
  fi
}

install_packages() {
  log "Paket listesi güncelleniyor..."
  apt-get -o Acquire::Retries=3 update
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  log "Paketler kuruluyor..."
  apt-get -o Acquire::Retries=3 install -y "${PACKAGES[@]}"
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 kurulamadı; docker-compose-v2 paketini doğrulayın."
  systemctl enable --now binfmt-support 2>/dev/null || true
  apt-get purge -y earlyoom 2>/dev/null || true
  systemctl disable --now earlyoom.service 2>/dev/null || true
  systemctl mask earlyoom.service 2>/dev/null || true
}

install_tailscale() {
  log "Tailscale kuruluyor..."
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  command -v tailscale >/dev/null ||
    die "Tailscale kurulumu tamamlanamadı."
  systemctl enable --now tailscaled
  if [[ -n "${TAILSCALE_AUTHKEY:-}" ]]; then
    tailscale up --auth-key="${TAILSCALE_AUTHKEY}" --accept-dns=false
    tailscale serve --bg http://127.0.0.1:8767
  else
    warn "Tailscale kuruldu fakat kimlik doğrulanmadı."
    warn "Paneli Tailscale üzerinden yayınlamak için: sudo tailscale up --accept-dns=false"
    warn "HTTPS erişimi için: sudo tailscale serve --bg http://127.0.0.1:8767"
  fi
}

prepare_layout() {
  log "Guardian dizinleri hazırlanıyor..."
  install -d -m 0755 "${APP_ROOT}" "${APP_ROOT}/core" "${APP_ROOT}/docker"
  install -d -m 0755 "${CONFIG_DIR}" "${APP_ROOT}/scripts" "${APP_ROOT}/network"
  install -d -o root -g "${SERVICE_USER}" -m 0750 "${APP_ROOT}/data"
  install -d -m 0750 "${ACTIVE_LOG_DIR}" "${ARCHIVE_LOG_DIR}"
  install -d -o root -g "${SERVICE_USER}" -m 0750 "${LOG_DIR}/anomaly"
  chown root:"${SERVICE_USER}" "${ACTIVE_LOG_DIR}" "${ARCHIVE_LOG_DIR}"
  chown root:"${SERVICE_USER}" "${ACTIVE_LOG_DIR}"
  install -d -o root -g root -m 0700 "${SAMPLE_DIR}"
  install -d -m 0750 "${ACTIVE_LOG_DIR}/dionaea"

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    useradd --system --home-dir "${APP_ROOT}" --shell /usr/sbin/nologin "${SERVICE_USER}"
  fi
  usermod -aG adm,pcap "${SERVICE_USER}" 2>/dev/null || true
  local target_user="${SUDO_USER:-}"
  if [[ -n "${target_user}" && "${target_user}" != "root" ]] && id -u "${target_user}" >/dev/null 2>&1; then
    usermod -aG docker "${target_user}"
  fi
}

install_application() {
  log "Uygulama kaynakları kopyalanıyor..."
  install -m 0644 "${REPO_ROOT}/core/config.py" "${APP_ROOT}/core/config.py"
  install -m 0644 "${REPO_ROOT}/core/logger.py" "${APP_ROOT}/core/logger.py"
  install -m 0644 "${REPO_ROOT}/core/sniffer.py" "${APP_ROOT}/core/sniffer.py"
  install -m 0644 "${REPO_ROOT}/core/detectors.py" "${APP_ROOT}/core/detectors.py"
  install -m 0644 "${REPO_ROOT}/core/dashboard.py" "${APP_ROOT}/core/dashboard.py"
  install -m 0644 "${REPO_ROOT}/core/health.py" "${APP_ROOT}/core/health.py"
  install -m 0644 "${REPO_ROOT}/core/system_monitor.py" "${APP_ROOT}/core/system_monitor.py"
  install -d -m 0755 "${APP_ROOT}/storage" "${APP_ROOT}/web"
  install -m 0644 "${REPO_ROOT}/storage/__init__.py" "${APP_ROOT}/storage/__init__.py"
  install -m 0644 "${REPO_ROOT}/storage/repository.py" "${APP_ROOT}/storage/repository.py"
  install -m 0644 "${REPO_ROOT}/web/__init__.py" "${APP_ROOT}/web/__init__.py"
  install -m 0644 "${REPO_ROOT}/web/api.py" "${APP_ROOT}/web/api.py"
  install -m 0644 "${REPO_ROOT}/web/auth.py" "${APP_ROOT}/web/auth.py"
  install -m 0644 "${REPO_ROOT}/web/app.py" "${APP_ROOT}/web/app.py"
  install -d -m 0755 "${APP_ROOT}/templates"
  install -m 0644 "${REPO_ROOT}/templates/login.html" "${APP_ROOT}/templates/login.html"
  install -m 0644 "${REPO_ROOT}/requirements.txt" "${APP_ROOT}/requirements.txt"
  install -m 0644 "${REPO_ROOT}/requirements-anomaly.txt" "${APP_ROOT}/requirements-anomaly.txt"
  install -m 0644 "${REPO_ROOT}/requirements-soc.txt" "${APP_ROOT}/requirements-soc.txt"

  python3 -m venv "${APP_ROOT}/venv"
  "${APP_ROOT}/venv/bin/pip" install --require-hashes --no-cache-dir \
    -r "${APP_ROOT}/requirements.txt"
  "${APP_ROOT}/venv/bin/pip" install --no-cache-dir \
    -r "${REPO_ROOT}/requirements-anomaly.txt"
  "${APP_ROOT}/venv/bin/pip" install --no-cache-dir \
    -r "${APP_ROOT}/requirements-soc.txt"
  chown -R root:root "${APP_ROOT}/venv" "${APP_ROOT}/core"
  chown -R root:root "${APP_ROOT}/storage" "${APP_ROOT}/web"
  chown -R root:root "${APP_ROOT}/templates"
}

configure_ssh() {
  log "SSH erişimi yapılandırılıyor..."
  local login_user="${SUDO_USER:-}"
  if [[ -z "${login_user}" || "${login_user}" == "root" ]]; then
    login_user="$(logname 2>/dev/null || true)"
  fi
  [[ -n "${login_user}" && "${login_user}" != "root" ]] ||
    die "SSH parolası için root olmayan kurulum kullanıcısı belirlenemedi."
  id -u "${login_user}" >/dev/null 2>&1 ||
    die "Kurulum kullanıcısı bulunamadı: ${login_user}"

  SSH_LOGIN_USER="${login_user}"
  local login_home
  login_home="$(getent passwd "${login_user}" | cut -d: -f6)"
  [[ -n "${login_home}" && -f "${login_home}/.google_authenticator" ]] ||
    die "MFA kaydı bulunamadı: önce ${login_user} için google-authenticator çalıştırın."
  chown "${login_user}:${login_user}" "${login_home}/.google_authenticator"
  chmod 600 "${login_home}/.google_authenticator"

  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-guardian-access.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication yes
AuthenticationMethods keyboard-interactive:pam
UsePAM yes
EOF
  /usr/sbin/sshd -t
  systemctl enable --now ssh
  systemctl restart ssh
}

configure_memory() {
  log "Swap ve ZRAM yapılandırılıyor..."
  if [[ ! -f "${SWAPFILE}" ]]; then
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count=2048 status=none
    chmod 600 "${SWAPFILE}"
    mkswap "${SWAPFILE}" >/dev/null
  elif ! file "${SWAPFILE}" 2>/dev/null | grep -q 'swap file'; then
    die "${SWAPFILE} mevcut fakat swap dosyası değil. Dosyayı inceleyip taşıyın veya kaldırın."
  fi
  chmod 600 "${SWAPFILE}"
  ensure_line "${SWAPFILE} none swap sw 0 0" /etc/fstab
  swapon -p 10 "${SWAPFILE}" 2>/dev/null || true

  cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl restart zramswap.service 2>/dev/null ||
    systemctl restart zram-tools.service 2>/dev/null || true

  systemctl disable --now swapspace 2>/dev/null || true
}

configure_kernel_and_watchdog() {
  log "Kernel ve watchdog ayarları uygulanıyor..."
  cat > /etc/sysctl.d/99-guardian.conf <<'EOF'
vm.swappiness=60
vm.vfs_cache_pressure=50
net.ipv4.tcp_syncookies=1
net.ipv4.tcp_max_syn_backlog=4096
net.ipv4.tcp_fin_timeout=15
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  sysctl --system >/dev/null

  cat > /etc/watchdog.conf <<'EOF'
watchdog-device = /dev/watchdog
watchdog-timeout = 15
max-load-1 = 24
EOF
  if [[ -e /dev/watchdog || -e /dev/watchdog0 ]]; then
    systemctl enable --now watchdog
  else
    warn "/dev/watchdog veya /dev/watchdog0 bulunamadı; watchdog etkinleştirilmedi."
    systemctl disable --now watchdog 2>/dev/null || true
  fi
}

configure_network_and_services() {
  log "Docker, ağ, Avahi, fail2ban ve systemd yapılandırılıyor..."
  systemctl enable --now NetworkManager docker fail2ban
  systemctl enable --now binfmt-support 2>/dev/null || true
  install -m 0644 "${REPO_ROOT}/docker/docker-compose.yml" "${APP_ROOT}/docker/docker-compose.yml"
  install -m 0755 "${REPO_ROOT}/scripts/guardian-healthcheck.sh" \
    /usr/local/sbin/guardian-healthcheck.sh
  install -m 0644 "${REPO_ROOT}/service/guardian-healthcheck.service" \
    /etc/systemd/system/guardian-healthcheck.service
  install -m 0644 "${REPO_ROOT}/service/guardian-healthcheck.timer" \
    /etc/systemd/system/guardian-healthcheck.timer
  install -m 0755 "${REPO_ROOT}/scripts/audit_parser.py" "${APP_ROOT}/scripts/audit_parser.py"
  install -m 0755 "${REPO_ROOT}/scripts/config_check.py" "${APP_ROOT}/scripts/config_check.py"
  install -m 0755 "${REPO_ROOT}/scripts/config_backup.sh" "${APP_ROOT}/scripts/config_backup.sh"
  install -m 0755 "${REPO_ROOT}/scripts/anomaly_daily.py" "${APP_ROOT}/scripts/anomaly_daily.py"
  install -m 0755 "${REPO_ROOT}/scripts/cowrie_log_parser.py" "${APP_ROOT}/scripts/cowrie_log_parser.py"
  install -m 0755 "${REPO_ROOT}/scripts/package-status-check.sh" \
    "${APP_ROOT}/scripts/package-status-check.sh"
  install -m 0755 "${REPO_ROOT}/scripts/optimize_system.sh" \
    "${APP_ROOT}/scripts/optimize_system.sh"
  install -m 0755 "${REPO_ROOT}/scripts/fan_control.py" \
    "${APP_ROOT}/scripts/fan_control.py"
  install -m 0755 "${REPO_ROOT}/scripts/check_throttle.sh" \
    "${APP_ROOT}/scripts/check_throttle.sh"
  install -m 0644 "${REPO_ROOT}/service/guardian-audit-parser.service" \
    /etc/systemd/system/guardian-audit-parser.service
  install -m 0644 "${REPO_ROOT}/service/guardian-config-backup.service" \
    /etc/systemd/system/guardian-config-backup.service
  install -m 0644 "${REPO_ROOT}/service/guardian-config-backup.timer" \
    /etc/systemd/system/guardian-config-backup.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-anomaly.service" \
    /etc/systemd/system/guardian-anomaly.service
  install -m 0644 "${REPO_ROOT}/service/guardian-anomaly.timer" \
    /etc/systemd/system/guardian-anomaly.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-cowrie.service" \
    /etc/systemd/system/guardian-cowrie.service
  install -m 0644 "${REPO_ROOT}/service/guardian-cowrie-parser.service" \
    /etc/systemd/system/guardian-cowrie-parser.service
  install -m 0644 "${REPO_ROOT}/service/guardian-package-status.service" \
    /etc/systemd/system/guardian-package-status.service
  install -m 0644 "${REPO_ROOT}/service/guardian-fan.service" \
    /etc/systemd/system/guardian-fan.service
  install -m 0644 "${REPO_ROOT}/service/guardian-throttle.service" \
    /etc/systemd/system/guardian-throttle.service
  install -m 0644 "${REPO_ROOT}/service/guardian-throttle.timer" \
    /etc/systemd/system/guardian-throttle.timer
  install -d -m 0755 "${APP_ROOT}/docker/cowrie"
  install -m 0644 "${REPO_ROOT}/docker/cowrie/docker-compose.yml" \
    "${APP_ROOT}/docker/cowrie/docker-compose.yml"
  install -d -m 0755 "${CONFIG_DIR}/cowrie"
  install -m 0640 "${REPO_ROOT}/config/cowrie/cowrie.cfg" "${CONFIG_DIR}/cowrie/cowrie.cfg"
  install -d -m 0770 "${APP_ROOT}/cowrie/log" "${APP_ROOT}/cowrie/tty" "${APP_ROOT}/cowrie/downloads"
  install -d -m 0755 /etc/audit/rules.d
  install -m 0640 "${REPO_ROOT}/ops/auditd/guardian.rules" /etc/audit/rules.d/guardian.rules
  install -m 0644 "${REPO_ROOT}/config/.gitignore" "${CONFIG_DIR}/.gitignore"
  cat > "${CONFIG_DIR}/guardian.conf" <<EOF
INTERFACE=auto
PRIMARY_INTERFACE=auto
EVENT_LOG=${ACTIVE_LOG_DIR}/events.jsonl
EVENT_DB=${APP_ROOT}/data/events.db
HONEYPOT_ENABLED=0
HONEYPOT_TYPE=dionaea
AUDITD_ENABLED=1
CONFIG_BACKUP_ENABLED=1
ANOMALY_ENABLED=1
ANOMALY_THRESHOLD=3
COWRIE_PORT=2222
TRUSTED_DHCP_SERVERS=
DNS_MAX_NAME_LENGTH=80
ICMP_PAYLOAD_LIMIT=256
ICMP_RATE_LIMIT=10
SLOW_SCAN_WINDOW_SECONDS=900
SLOW_SCAN_THRESHOLD=20
MAC_FLOOD_THRESHOLD=200
THREAT_INTEL_BLOCKLIST=${CONFIG_DIR}/blocklist.txt
DETECTOR_ARP_SPOOF=1
DETECTOR_ROGUE_DHCP=1
DETECTOR_DNS=1
DETECTOR_ICMP=1
DETECTOR_SLOW_PORT_SCAN=1
DETECTOR_NEW_DEVICE=1
DETECTOR_MAC_FLOODING=1
DETECTOR_THREAT_INTEL=1
PORT_SCAN_THRESHOLD=20
CONNECTION_RATE_THRESHOLD=60
WINDOW_SECONDS=60
EGRESS_QUARANTINE=1
EOF
  install -d -m 0755 /etc/systemd/system/guardian-core.service.d
  install -m 0644 "${REPO_ROOT}/service/guardian-core.service.d/config-check.conf" \
    /etc/systemd/system/guardian-core.service.d/config-check.conf
  chmod 0640 "${CONFIG_DIR}/guardian.conf"
  chown root:"${SERVICE_USER}" "${CONFIG_DIR}/guardian.conf"
  install -m 0640 -o root -g "${SERVICE_USER}" /dev/null "${CONFIG_DIR}/blocklist.txt"

  cat > "${APP_ROOT}/network/iptables_rules.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly CHAIN="GUARDIAN_DOCKER_EGRESS"
case "${1:-apply}" in
  apply)
    iptables -N "${CHAIN}" 2>/dev/null || true
    iptables -F "${CHAIN}"
    iptables -C DOCKER-USER -j "${CHAIN}" 2>/dev/null || iptables -I DOCKER-USER -j "${CHAIN}"
    iptables -A "${CHAIN}" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
    for subnet in 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12; do
      iptables -A "${CHAIN}" -d "${subnet}" -j DROP
    done
    iptables -A "${CHAIN}" -j DROP
    ;;
  remove)
    iptables -D DOCKER-USER -j "${CHAIN}" 2>/dev/null || true
    iptables -F "${CHAIN}" 2>/dev/null || true
    iptables -X "${CHAIN}" 2>/dev/null || true
    ;;
  status) iptables -S "${CHAIN}" ;;
  *) printf 'Usage: %s {apply|remove|status}\n' "$0" >&2; exit 2 ;;
esac
EOF
  chmod 755 "${APP_ROOT}/network/iptables_rules.sh"
  docker compose -f "${APP_ROOT}/docker/docker-compose.yml" config >/dev/null ||
    die "Dionaea Docker Compose yapılandırması geçersiz."
  docker compose -f "${APP_ROOT}/docker/cowrie/docker-compose.yml" config >/dev/null ||
    die "Cowrie Docker Compose yapılandırması geçersiz."
  install -m 0755 "${REPO_ROOT}/scripts/guardian-honeypot.sh" \
    /usr/local/sbin/guardian-honeypot.sh

  cat > /etc/NetworkManager/dispatcher.d/99-honeypot-adapt.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly LOG="/var/log/guardian-network.log"
interface="${1:-unknown}"
state="${2:-unknown}"
{
  printf '%s interface=%s state=%s\n' "$(date --iso-8601=seconds)" "${interface}" "${state}"
  ip -4 addr show dev "${interface}" 2>/dev/null || true
  ip -4 route show dev "${interface}" 2>/dev/null || true
} >> "${LOG}"
if [[ "${state}" == "up" || "${state}" == "dhcp4-change" || "${state}" == "connectivity-change" ]]; then
  /opt/guardian/network/iptables_rules.sh apply 2>/dev/null || true
  systemctl try-restart guardian-core.service 2>/dev/null || true
fi
EOF
  chown root:root /etc/NetworkManager/dispatcher.d/99-honeypot-adapt.sh
  chmod 755 /etc/NetworkManager/dispatcher.d/99-honeypot-adapt.sh

  install -m 0644 "${REPO_ROOT}/config/avahi-printer.service" \
    /etc/avahi/services/guardian-printer.service
  systemctl restart avahi-daemon

  cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
backend = systemd
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
EOF
  cat > /etc/pam.d/guardian-google-authenticator <<'EOF'
auth required pam_google_authenticator.so
EOF
  ensure_line "auth required pam_google_authenticator.so" /etc/pam.d/sshd

  cat > /etc/systemd/system/guardian-core.service <<'EOF'
[Unit]
Description=Guardian Scapy network analysis engine
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=notify
WorkingDirectory=/opt/guardian/core
ExecStartPre=/usr/local/sbin/guardian-honeypot.sh
ExecStartPre=/opt/guardian/network/iptables_rules.sh apply
ExecStart=/opt/guardian/venv/bin/python3 /opt/guardian/core/sniffer.py --config /opt/guardian/config/guardian.conf
CPUAffinity=1 2
Restart=always
RestartSec=10
RuntimeMaxSec=86400
MemoryMax=300M
MemorySwapMax=100M
WatchdogSec=60
NotifyAccess=main
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/guardian/logs/active
ReadWritePaths=/opt/guardian/data

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  augenrules --load
  systemctl enable guardian-core.service
  systemctl enable --now guardian-audit-parser.service guardian-config-backup.timer guardian-anomaly.timer
  systemctl enable --now guardian-cowrie-parser.service
  systemctl enable --now guardian-healthcheck.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-health.service" \
    /etc/systemd/system/guardian-health.service
  install -m 0644 "${REPO_ROOT}/service/guardian-soc.service" \
    /etc/systemd/system/guardian-soc.service
  install -m 0644 "${REPO_ROOT}/service/guardian-web.service" \
    /etc/systemd/system/guardian-web.service
  install -d -m 0750 -o root -g "${SERVICE_USER}" /etc/guardian
  printf 'GUARDIAN_API_TOKEN=%s\n' "$(openssl rand -hex 32)" > /etc/guardian/web.env
  chown root:"${SERVICE_USER}" /etc/guardian/web.env
  chmod 0640 /etc/guardian/web.env
  install -d -m 0750 /etc/guardian
  cat > /etc/guardian/soc.env <<EOF
SECRET_KEY=${GUARDIAN_SOC_SECRET_KEY:-$(openssl rand -hex 32)}
JWT_SECRET_KEY=${JWT_SECRET_KEY:-$(openssl rand -hex 32)}
GUARDIAN_SOC_USERNAME=${GUARDIAN_SOC_USERNAME:-guardian}
GUARDIAN_SOC_PASSWORD_BCRYPT=${GUARDIAN_SOC_PASSWORD_BCRYPT:-}
GUARDIAN_SOC_TOTP_SECRET=${GUARDIAN_SOC_TOTP_SECRET:-}
GUARDIAN_LIMITER_STORAGE=memory://
EOF
  chown root:"${SERVICE_USER}" /etc/guardian/soc.env
  chmod 0640 /etc/guardian/soc.env
  install -m 0644 "${REPO_ROOT}/service/guardian-system-monitor.service" \
    /etc/systemd/system/guardian-system-monitor.service
  systemctl daemon-reload
  systemctl enable --now guardian-health.service
  systemctl enable --now guardian-web.service
  systemctl enable guardian-soc.service
  systemctl enable --now guardian-package-status.service
  systemctl enable --now guardian-fan.service guardian-throttle.timer
  systemctl enable --now guardian-system-monitor.service
}

configure_auxiliary_services() {
  log "Sıcaklık, log2ram, SQLite ve güncelleme servisleri yapılandırılıyor..."
  install -d -m 0750 /var/log/guardian
  install -m 0755 "${REPO_ROOT}/scripts/temperature-monitor.sh" \
    /usr/local/sbin/guardian-temperature-monitor.sh
  install -m 0755 "${REPO_ROOT}/scripts/log2ram-sync.sh" \
    /usr/local/sbin/guardian-log2ram-sync.sh
  install -d -m 0755 /usr/local/lib/guardian
  install -m 0755 "${REPO_ROOT}/scripts/sqlite-maintenance.py" \
    /usr/local/lib/guardian/sqlite-maintenance.py
  install -m 0644 "${REPO_ROOT}/service/guardian-temperature.service" \
    /etc/systemd/system/guardian-temperature.service
  install -m 0644 "${REPO_ROOT}/service/guardian-temperature.timer" \
    /etc/systemd/system/guardian-temperature.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-log2ram-sync.service" \
    /etc/systemd/system/guardian-log2ram-sync.service
  install -m 0644 "${REPO_ROOT}/service/guardian-log2ram-sync.timer" \
    /etc/systemd/system/guardian-log2ram-sync.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-sqlite-maintenance.service" \
    /etc/systemd/system/guardian-sqlite-maintenance.service
  install -m 0644 "${REPO_ROOT}/service/guardian-sqlite-maintenance.timer" \
    /etc/systemd/system/guardian-sqlite-maintenance.timer
  cat > /etc/log2ram.conf <<'EOF'
SIZE=128M
EOF
  ensure_line "tmpfs /var/log/guardian tmpfs rw,nosuid,nodev,noexec,size=128M,mode=0750 0 0" /etc/fstab
  mountpoint -q /var/log/guardian || mount /var/log/guardian
  install -d -m 0755 /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  cat > /etc/apt/apt.conf.d/52unattended-upgrades-guardian <<'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::SyslogEnable "true";
EOF
  systemctl daemon-reload
  systemctl enable --now unattended-upgrades
  systemctl enable --now guardian-temperature.timer guardian-log2ram-sync.timer
  systemctl enable --now guardian-sqlite-maintenance.timer
}

configure_archiving() {
  log "Günlük pigz arşivleme yapılandırılıyor..."
  cat > "${APP_ROOT}/scripts/archive_daily_logs.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
readonly ROOT="/opt/guardian"
readonly ACTIVE="${ROOT}/logs/active"
readonly ARCHIVE="${ROOT}/logs/archive"
readonly DAY="$(date -d yesterday +%F)"
readonly STAGE="$(mktemp -d /tmp/guardian-archive.XXXXXX)"
trap 'rm -rf "${STAGE}"' EXIT
mkdir -p "${ARCHIVE}"
find "${ACTIVE}" -maxdepth 1 -type f -name '*.jsonl' -size +0c -exec cp -- {} "${STAGE}/" \;
if find "${STAGE}" -type f -print -quit | grep -q .; then
  tar -C "${STAGE}" -cf - . | pigz -p "$(nproc)" > "${ARCHIVE}/${DAY}.tar.gz"
  find "${ACTIVE}" -maxdepth 1 -type f -name '*.jsonl' -exec truncate -s 0 {} \;
fi
find "${ARCHIVE}" -type f -name '*.tar.gz' -mtime +90 -delete
EOF
  chmod 755 "${APP_ROOT}/scripts/archive_daily_logs.sh"
  local cron_line="1 0 * * * ${APP_ROOT}/scripts/archive_daily_logs.sh"
  (crontab -l 2>/dev/null | grep -vF "${APP_ROOT}/scripts/archive_daily_logs.sh" || true; printf '%s\n' "${cron_line}") | crontab -
}

check_prerequisites() {
  local architecture ram_kb disk_kb
  architecture="$(uname -m)"
  if [[ "${architecture}" != "aarch64" ]]; then
    step_error "arm64/aarch64 bekleniyor, bulunan: ${architecture}"
    return 1
  fi
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    step_error "Ubuntu 24.04 bekleniyor, bulunan: ${PRETTY_NAME:-bilinmiyor}"
    return 1
  fi
  ram_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  if [[ ! "${ram_kb}" =~ ^[0-9]+$ || "${ram_kb}" -lt 3145728 ]]; then
    step_error "En az 3 GB RAM gerekli."
    return 1
  fi
  disk_kb="$(df -Pk / | awk 'NR == 2 {print $4}')"
  if [[ ! "${disk_kb}" =~ ^[0-9]+$ || "${disk_kb}" -lt 8388608 ]]; then
    step_error "Kök dosya sisteminde en az 8 GB boş alan gerekli."
    return 1
  fi
  preflight_checks
}

setup_performance() {
  configure_kernel_and_watchdog
  if [[ -x "${APP_ROOT}/scripts/optimize_system.sh" ]]; then
    "${APP_ROOT}/scripts/optimize_system.sh"
  else
    step_error "optimize_system.sh bulunamadı; temel kernel ayarları uygulandı."
  fi
}

setup_fan_control() {
  local config_file="/boot/firmware/config.txt"
  if [[ ! -f "${config_file}" ]]; then
    step_error "${config_file} bulunamadı; fan ayarı atlandı."
    return 1
  fi
  ensure_line "dtparam=fan_temp0=28000" "${config_file}"
  ensure_line "dtparam=fan_temp0_hyst=2000" "${config_file}"
  ensure_line "dtparam=fan_temp0_speed=75" "${config_file}"
  ensure_line "dtparam=fan_temp1=38000" "${config_file}"
  ensure_line "dtparam=fan_temp1_hyst=2000" "${config_file}"
  ensure_line "dtparam=fan_temp1_speed=150" "${config_file}"
  ensure_line "dtparam=fan_temp2=48000" "${config_file}"
  ensure_line "dtparam=fan_temp2_hyst=2000" "${config_file}"
  ensure_line "dtparam=fan_temp2_speed=255" "${config_file}"
  grep -q '^dtparam=fan_temp2_speed=255$' "${config_file}"
}

setup_python_env() {
  prepare_layout
  install_application
  [[ -x "${APP_ROOT}/venv/bin/python3" ]]
}

setup_services() {
  configure_network_and_services
  configure_auxiliary_services
  configure_archiving
  systemctl daemon-reload
  systemctl enable guardian-core.service guardian-web.service guardian-soc.service \
    guardian-fan.service guardian-throttle.timer guardian-package-status.service
}

run_tests() {
  local failures=0
  if ! "${APP_ROOT}/venv/bin/python3" -c "import scapy"; then
    step_error "Scapy import testi başarısız."
    failures=$((failures + 1))
  fi
  if command -v vcgencmd >/dev/null 2>&1; then
    vcgencmd measure_temp >/dev/null ||
      { step_error "vcgencmd measure_temp başarısız."; failures=$((failures + 1)); }
  else
    skip "vcgencmd bulunamadı; Pi dışı ortam olabilir."
  fi
  systemctl is-enabled guardian-fan.service >/dev/null 2>&1 ||
    { step_error "guardian-fan.service etkin değil."; failures=$((failures + 1)); }
  return "${failures}"
}

main() {
  run_step "Ön koşul kontrolü" check_prerequisites
  run_step "Paket kurulumu" install_packages
  run_step "Tailscale kurulumu" install_tailscale
  run_step "Python ortamı ve Guardian dizinleri" setup_python_env
  run_step "Performans ayarları" setup_performance
  run_step "Fan donanım ayarları" setup_fan_control
  run_step "Bellek ayarları" configure_memory
  run_step "Servis kurulumu" setup_services
  run_step "SSH yapılandırması" configure_ssh
  run_step "Throttle ve sistem testleri" run_tests
  log "Guardian servisi etkinleştiriliyor..."
  if systemctl start guardian-core.service; then
    ok "guardian-core.service başlatıldı."
  else
    step_error "guardian-core.service başlatılamadı; kurulum devam ediyor."
  fi
  log "Kurulum tamamlandı. Durum: systemctl --no-pager status guardian-core.service"
  printf '\nSSH mevcut kullanıcı ile etkinleştirildi:\n'
  printf '  Kullanıcı: %s\n' "${SSH_LOGIN_USER}"
  printf '  Bağlantı:  ssh %s@<RASPBERRY_PI_IP>\n\n' "${SSH_LOGIN_USER}"
}

main "$@"