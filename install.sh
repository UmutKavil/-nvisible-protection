#!/usr/bin/env bash
set -Eeuo pipefail
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

log() { printf '[guardian-install] %s\n' "$*"; }
warn() { printf '[guardian-install][WARN] %s\n' "$*" >&2; }
die() { printf '[guardian-install][ERROR] %s\n' "$*" >&2; exit 1; }
trap 'die "Kurulum ${BASH_SOURCE[0]}:${LINENO} satırında başarısız oldu."' ERR

[[ "${EUID}" -eq 0 ]] || die "Root yetkisi gerekli: sudo ./install.sh"
[[ "$(uname -m)" == "aarch64" ]] || die "Raspberry Pi 5 Ubuntu arm64/aarch64 gereklidir."
[[ -r /etc/os-release ]] || die "/etc/os-release bulunamadı."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu Server gereklidir: ${PRETTY_NAME:-bilinmiyor}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

readonly PACKAGES=(
  build-essential pigz htop iotop git curl wget jq zram-tools watchdog irqbalance
  swapspace network-manager avahi-daemon avahi-utils iproute2 iptables
  iw libpcap-dev tcpdump tshark fail2ban libpam-google-authenticator docker.io
  docker-compose python3-pip python3-venv python3-full openssh-server
)

ensure_line() {
  local line="$1" file="$2"
  grep -qxF "${line}" "${file}" 2>/dev/null || printf '%s\n' "${line}" >> "${file}"
}

install_packages() {
  log "Paket listesi güncelleniyor..."
  apt-get update
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  log "Paketler kuruluyor..."
  apt-get install -y "${PACKAGES[@]}"
  apt-get purge -y earlyoom 2>/dev/null || true
  systemctl disable --now earlyoom.service 2>/dev/null || true
  systemctl mask earlyoom.service 2>/dev/null || true
}

prepare_layout() {
  log "Guardian dizinleri hazırlanıyor..."
  install -d -m 0755 "${APP_ROOT}" "${APP_ROOT}/core" "${APP_ROOT}/docker"
  install -d -m 0755 "${CONFIG_DIR}" "${APP_ROOT}/scripts" "${APP_ROOT}/network"
  install -d -m 0755 "${ACTIVE_LOG_DIR}" "${ARCHIVE_LOG_DIR}"
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
  install -m 0644 "${REPO_ROOT}/core/dashboard.py" "${APP_ROOT}/core/dashboard.py"
  install -m 0644 "${REPO_ROOT}/requirements.txt" "${APP_ROOT}/requirements.txt"

  python3 -m venv "${APP_ROOT}/venv"
  "${APP_ROOT}/venv/bin/pip" install --upgrade pip
  "${APP_ROOT}/venv/bin/pip" install scapy rich psutil
  chown -R root:root "${APP_ROOT}/venv" "${APP_ROOT}/core"
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
  install -d -m 0755 /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-guardian-access.conf <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
EOF
  /usr/sbin/sshd -t
  systemctl enable --now ssh
  systemctl restart ssh
}

configure_memory() {
  log "Swap ve ZRAM yapılandırılıyor..."
  if [[ ! -f "${SWAPFILE}" ]]; then
    dd if=/dev/zero of="${SWAPFILE}" bs=1M count=4096 status=none
  fi
  chmod 600 "${SWAPFILE}"
  mkswap "${SWAPFILE}" >/dev/null
  ensure_line "${SWAPFILE} none swap sw 0 0" /etc/fstab
  swapon -p 10 "${SWAPFILE}" 2>/dev/null || true

  cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
  systemctl restart zramswap.service 2>/dev/null ||
    systemctl restart zram-tools.service 2>/dev/null || true

  cat > /etc/swapspace.conf <<'EOF'
chunk_size=2048m
max_swap_size=16384m
min_free_space=20480m
EOF
  systemctl enable --now swapspace
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
  install -m 0644 "${REPO_ROOT}/docker/docker-compose.yml" "${APP_ROOT}/docker/docker-compose.yml"
  cat > "${CONFIG_DIR}/guardian.conf" <<EOF
INTERFACE=auto
PRIMARY_INTERFACE=auto
EVENT_LOG=${ACTIVE_LOG_DIR}/events.jsonl
PORT_SCAN_THRESHOLD=20
CONNECTION_RATE_THRESHOLD=60
WINDOW_SECONDS=60
EGRESS_QUARANTINE=1
EOF
  chmod 0640 "${CONFIG_DIR}/guardian.conf"
  chown root:"${SERVICE_USER}" "${CONFIG_DIR}/guardian.conf"

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
  if [[ "${interface}" == "eth0" ]]; then
    while ip route del default dev wlan0 2>/dev/null; do :; done
  elif [[ "${interface}" == "wlan0" ]]; then
    while ip route del default dev eth0 2>/dev/null; do :; done
  fi
  /opt/guardian/network/iptables_rules.sh apply 2>/dev/null || true
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
auth required pam_google_authenticator.so nullok
EOF
  ensure_line "auth required pam_google_authenticator.so nullok" /etc/pam.d/sshd

  cat > /etc/systemd/system/guardian-core.service <<'EOF'
[Unit]
Description=Guardian Scapy network analysis engine
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/guardian/core
ExecStartPre=/usr/bin/docker compose -f /opt/guardian/docker/docker-compose.yml up -d
ExecStartPre=/opt/guardian/network/iptables_rules.sh apply
ExecStart=/opt/guardian/venv/bin/python3 /opt/guardian/core/sniffer.py --config /opt/guardian/config/guardian.conf
CPUAffinity=1 2
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/guardian/logs/active

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now NetworkManager docker fail2ban
  systemctl enable guardian-core.service
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

main() {
  install_packages
  prepare_layout
  install_application
  configure_memory
  configure_kernel_and_watchdog
  configure_network_and_services
  configure_archiving
  configure_ssh
  [[ "$(hostname)" == "${ORIGINAL_HOSTNAME}" ]] ||
    die "Kurulum sırasında cihaz hostname'i değişti; mevcut isim korunamadı."
  log "Guardian servisi etkinleştiriliyor..."
  systemctl start guardian-core.service
  log "Kurulum tamamlandı. Durum: systemctl --no-pager status guardian-core.service"
  printf '\nSSH mevcut kullanıcı ile etkinleştirildi:\n'
  printf '  Kullanıcı: %s\n' "${SSH_LOGIN_USER}"
  printf '  Bağlantı:  ssh %s@<RASPBERRY_PI_IP>\n\n' "${SSH_LOGIN_USER}"
}

main "$@"