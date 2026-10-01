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
- zstd ZRAM, 4 GB swapfile, swapspace ve watchdog
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
3. earlyoom'u kaldırır/maskeler; zstd ZRAM, 4 GB swapfile, swapspace ve watchdog'u etkinleştirir.
4. `/etc/sysctl.d/99-guardian.conf` ile çekirdek ağ ve bellek korumalarını uygular.
5. Sistem Python paketlerini kullanan `guardian` Python sanal ortamını oluşturur.
6. Ağ arayüzü, honeypot portları ve log dizinini yapılandırır.
7. Docker Compose ile Dionaea'yı başlatır; 4. CPU ve 1 GB RAM limiti uygular.
8. NetworkManager dispatcher, guardian servisi ve log arşiv timer'ını etkinleştirir.
9. fail2ban ve SSH MFA hazırlığını kurar.
10. OpenSSH yoksa kurar; mevcut kullanıcı adı ve sistem parolası değiştirilmeden SSH'ı etkinleştirir.
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
- Google Authenticator PAM satırı `nullok` ile hazırlanır; MFA otomatik zorlanmaz. Kullanıcı için `google-authenticator` çalıştırıp mevcut SSH oturumu doğrulandıktan sonra `AuthenticationMethods publickey,keyboard-interactive:pam` satırını etkinleştirin.
- SSH parola erişimi mevcut sistem parolasıyla kullanılır. Kurulum kullanıcı adını veya parolasını değiştirmez.
- `config/guardian.conf` içindeki `EGRESS_QUARANTINE` ve `AVAHI_ENABLED` ayarlarını bilinçli değiştirin.

Egress kuralları Docker'ın `DOCKER-USER` zincirinde uygulanır. Mevcut host firewall kuralları silinmez. İkincil arayüz bağlandığında, `PRIMARY_INTERFACE` seçilmişse o arayüzdeki default route kaldırılır; bu nedenle kurulum sırasında yönetim bağlantısının birincil arayüzünü doğru seçin.

## Geliştirme

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests
```
