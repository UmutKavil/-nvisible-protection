# Invisible Protection

Raspberry Pi 5 üzerinde çalışan, Dionaea honeypot ve Scapy tabanlı ağ gözlem servisinden oluşan savunma amaçlı ağ izleme sistemi.

## Kapsam

- JSON formatında olay kaydı
- Port taraması ve bağlantı yoğunluğu için temel anomali tespiti
- Rich tabanlı canlı terminal paneli
- Dionaea konteyneri
- Docker `DOCKER-USER` zinciri üzerinden egress karantinası
- Ethernet/Wi-Fi arayüz değişikliklerine uyum
- Günlük logların `pigz` ile arşivlenmesi
- systemd ile otomatik başlatma
- zstd ZRAM, 2 GB swapfile ve watchdog
- SYN flood/sysctl korumaları
- RFC1918 egress engeli ve izole malware örnek dizini
- fail2ban ve Google Authenticator için SSH MFA hazırlığı
- OpenSSH kurulumu; mevcut kullanıcı adı ve parola korunur
- Cihaz hostname'i, `/etc/hostname`, `/etc/hosts` ve machine-id değiştirilmez

> İlk sürüm yalnızca Raspberry Pi'nin gördüğü trafiği izler. Ağdaki tüm cihazları görmek için Pi'nin gateway/bridge veya mirror port konumunda olması gerekir.

## Gereksinimler

- 64-bit Ubuntu Server 24.04 (Raspberry Pi 5 için)
- Raspberry Pi 5, 4 GB veya üzeri RAM
- Aktif soğutma ve güvenilir güç kaynağı
- Ethernet önerilir
- Root yetkisi

## Kurulum

```bash
git clone <repo-url> ~/invisible-protection
cd ~/invisible-protection
sudo ./install.sh
```

Kurulum scripti:

1. Ubuntu Server 24.04 ve 64-bit arm64 mimariyi doğrular.
2. Gerekli sistem paketlerini kurar.
3. earlyoom'u kaldırır/maskeler; zstd ZRAM, 2 GB swapfile ve watchdog'u etkinleştirir.
4. `/etc/sysctl.d/99-guardian.conf` ile çekirdek ağ ve bellek korumalarını uygular.
5. Sistem Python paketlerini kullanan `guardian` Python sanal ortamını oluşturur.
6. Ağ arayüzü, honeypot portları ve log dizinini yapılandırır.
7. Docker Compose ile Dionaea'yı başlatır; 4. CPU ve 1 GB RAM limiti uygular. Mevcut sabit Dionaea imajı amd64 olduğundan Pi 5 üzerinde qemu/binfmt ile çalıştırılır.
8. NetworkManager dispatcher, guardian servisi ve log arşiv timer'ını etkinleştirir.
9. fail2ban ve zorunlu SSH MFA yapılandırmasını kurar. Kurulumdan önce kurulum kullanıcısı için `google-authenticator` çalıştırılmalıdır.
10. OpenSSH yoksa kurar; mevcut kullanıcı adı korunur, SSH parola doğrulaması kapatılır ve PAM üzerinden MFA zorunlu kılınır.
11. Mevcut cihaz hostname'ini doğrular; isim değişmişse kurulumu hata ile durdurur.
12. Servislerin durumunu ve temel health check sonuçlarını gösterir.

Kurulum sırasında egress karantinası, Avahi kamuflajı ve birincil arayüz seçimi istenir. Egress ve Avahi varsayılan olarak kapalıdır. RFC1918 yönlerine giden Docker trafiği her durumda engellenir.

## Servisler

```bash
systemctl status guardian-core.service
systemctl status guardian-log-archive.timer
docker compose -f /opt/guardian/docker/docker-compose.yml ps
```

Kurulum tamamlandığında mevcut SSH kullanıcı adı gösterilir; kullanıcı adı veya parola değiştirilmez:

```bash
ssh <kullanıcı>@<RASPBERRY_PI_IP>
```

Canlı dashboard:

```bash
sudo journalctl -u guardian-core.service -f
```

Olay logları `/opt/guardian/logs/active/events.jsonl` altında tutulur.

## Güvenlik notları

- Dionaea yalnızca yetkili olduğunuz ağlarda çalıştırılmalıdır.
- Kurulum, mevcut firewall kurallarını silmez; yalnızca kendi zincirlerini yönetir.
- `guardian-core` root olarak çalışır çünkü paket yakalama ve ağ bilgisi için yetki gerekir. Python kodu kullanıcı girdisini komut olarak çalıştırmaz.
- Honeypot yönetimi için Docker socket konteynere bağlanmaz.
- Malware örnekleri `/opt/guardian/malware_samples` altında `0700` izinlerle tutulur.
- Kurulumdan önce SSH kullanıcısı için `google-authenticator` çalıştırılmalıdır. Kurulum, `~/.google_authenticator` yoksa MFA etkinleştirmeden durur.
- SSH parola doğrulaması kapalıdır; `keyboard-interactive:pam` üzerinden sistem parolası ve Google Authenticator kodu birlikte istenir. Kurulum kullanıcı adı veya parolası değiştirilmez.
- `config/guardian.conf` içindeki `EGRESS_QUARANTINE` ve `AVAHI_ENABLED` ayarlarını bilinçli değiştirin.
- Mevcut sabit Dionaea imajı amd64'tür ve Pi 5'te qemu/binfmt emülasyonu ile çalışır. Bu yerel imajdan daha yavaş olabilir; üretimde arm64 uyumlu, doğrulanmış bir imaj bulunduğunda `platform` ve digest birlikte güncellenmelidir.

Egress kuralları Docker'ın `DOCKER-USER` zincirinde uygulanır. Mevcut host firewall kuralları silinmez. İkincil arayüz bağlandığında, `PRIMARY_INTERFACE` seçilmişse o arayüzdeki default route kaldırılır; bu nedenle kurulum sırasında yönetim bağlantısının birincil arayüzünü doğru seçin.

## Geliştirme

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests
```
