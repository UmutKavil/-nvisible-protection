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
on_error() {
  local exit_code=$?
  printf '[guardian-install][ERROR] Kurulum başarısız oldu (satır %s, çıkış kodu %s).\n' \
    "${BASH_LINENO[0]}" "${exit_code}" >&2
  printf '[guardian-install][ERROR] Başarısız komut: %s\n' "${BASH_COMMAND}" >&2
  printf '[guardian-install][ERROR] Sebep genellikle yukarıdaki paket, izin, disk, ağ veya servis hatasıdır.\n' >&2
  printf '[guardian-install][ERROR] Yeniden denemeden önce: journalctl -xe, systemctl --failed ve df -h çıktısını kontrol edin.\n' >&2
  exit "${exit_code}"
}
trap on_error ERR

[[ "${EUID}" -eq 0 ]] || die "Root yetkisi gerekli: sudo ./install.sh"
[[ "$(uname -m)" == "aarch64" ]] || die "Raspberry Pi 5 Ubuntu arm64/aarch64 gereklidir."
[[ -r /etc/os-release ]] || die "/etc/os-release bulunamadı."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Ubuntu Server gereklidir: ${PRETTY_NAME:-bilinmiyor}"
[[ "${VERSION_ID:-}" == "24.04" ]] ||
  die "Ubuntu 24.04 gereklidir; bulunan sürüm: ${PRETTY_NAME:-bilinmiyor}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

readonly PACKAGES=(
  build-essential pigz htop iotop git curl wget jq zram-tools watchdog irqbalance
  network-manager avahi-daemon avahi-utils iproute2 iptables
  iw libpcap-dev tcpdump tshark fail2ban docker.io file
  libpam-google-authenticator
  docker-compose-v2 qemu-user-static binfmt-support python3-pip python3-venv
  python3-full openssh-server unattended-upgrades
)

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

prepare_layout() {
  log "Guardian dizinleri hazırlanıyor..."
  install -d -m 0755 "${APP_ROOT}" "${APP_ROOT}/core" "${APP_ROOT}/docker"
  install -d -m 0755 "${CONFIG_DIR}" "${APP_ROOT}/scripts" "${APP_ROOT}/network"
  install -d -m 0750 "${APP_ROOT}/data"
  install -d -m 0755 "${ACTIVE_LOG_DIR}" "${ARCHIVE_LOG_DIR}"
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
  install -m 0644 "${REPO_ROOT}/core/dashboard.py" "${APP_ROOT}/core/dashboard.py"
  install -m 0644 "${REPO_ROOT}/core/health.py" "${APP_ROOT}/core/health.py"
  install -m 0644 "${REPO_ROOT}/requirements.txt" "${APP_ROOT}/requirements.txt"

  python3 -m venv "${APP_ROOT}/venv"
  "${APP_ROOT}/venv/bin/pip" install --require-hashes --no-cache-dir \
    -r "${APP_ROOT}/requirements.txt"
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
  cat > "${CONFIG_DIR}/guardian.conf" <<EOF
INTERFACE=auto
PRIMARY_INTERFACE=auto
EVENT_LOG=${ACTIVE_LOG_DIR}/events.jsonl
EVENT_DB=${APP_ROOT}/data/events.db
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
  docker compose -f "${APP_ROOT}/docker/docker-compose.yml" config >/dev/null ||
    die "Dionaea Docker Compose yapılandırması geçersiz."
  docker pull --platform linux/amd64 \
    "dinotools/dionaea@sha256:6f06d0a6035c865cb60ef51bd96ff3b1f25ee4bfcd852dad3f551bc2d93464ca" ||
    die "Dionaea amd64 imajı indirilemedi; qemu/binfmt veya ağ bağlantısını doğrulayın."

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
ExecStartPre=/usr/bin/docker compose -f /opt/guardian/docker/docker-compose.yml up -d
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
  systemctl enable guardian-core.service
  systemctl enable --now guardian-healthcheck.timer
  install -m 0644 "${REPO_ROOT}/service/guardian-health.service" \
    /etc/systemd/system/guardian-health.service
  systemctl daemon-reload
  systemctl enable --now guardian-health.service
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

main() {
  preflight_checks
  install_packages
  prepare_layout
  install_application
  configure_memory
  configure_kernel_and_watchdog
  configure_network_and_services
  configure_auxiliary_services
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