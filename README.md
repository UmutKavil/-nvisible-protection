# Invisible Protection

Raspberry Pi 5 üzerinde çalışan, Dionaea honeypot ve Scapy tabanlı ağ gözlem servisinden oluşan savunma amaçlı ağ izleme sistemi.

## Kapsam

- JSON formatında olay kaydı
- Port taraması ve bağlantı yoğunluğu için temel anomali tespiti
- Rich tabanlı canlı terminal paneli
- Dionaea veya Cowrie konteyneri (seçilebilir)
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

Kurulum başlamadan önce script; Ubuntu 24.04 arm64, en az 3 GB RAM, 8 GB boş disk,
DNS/ağ bağlantısı ve aktif apt/dpkg işlemi kontrolü yapar. Kontrollerden biri
başarısız olursa kurulum değişiklik yapmadan durur. Kurulum sırasında hata oluşursa
çıktıda başarısız satır ve komut gösterilir. Yeniden denemeden önce şu komutlarla
durumu inceleyin:

```bash
df -h
free -h
systemctl --failed
journalctl -xe --no-pager
```

Kurulum güvenli şekilde tekrar çalıştırılabilir. Mevcut `/swapfile` swap dosyası
değilse script bunu açıkça bildirir ve üzerine yazmaz.

Kurulum scripti:

1. Ubuntu Server 24.04 ve 64-bit arm64 mimariyi doğrular.
2. Gerekli sistem paketlerini kurar.
3. earlyoom'u kaldırır/maskeler; zstd ZRAM, 2 GB swapfile ve watchdog'u etkinleştirir.
4. `/etc/sysctl.d/99-guardian.conf` ile çekirdek ağ ve bellek korumalarını uygular.
5. Sistem Python paketlerini kullanan `guardian` Python sanal ortamını oluşturur.
6. Ağ arayüzü, honeypot portları ve log dizinini yapılandırır.
7. Dionaea honeypot varsayılan olarak kapalıdır; `HONEYPOT_ENABLED=1` verilirse Compose ile CPU ve 256 MB RAM limiti altında başlatılır.
8. NetworkManager dispatcher, guardian servisi ve log arşiv timer'ını etkinleştirir.
9. fail2ban ve zorunlu SSH MFA yapılandırmasını kurar. Kurulumdan önce kurulum kullanıcısı için `google-authenticator` çalıştırılmalıdır.
10. OpenSSH yoksa kurar; mevcut kullanıcı adı korunur, SSH parola doğrulaması kapatılır ve PAM üzerinden MFA zorunlu kılınır.
11. Mevcut cihaz hostname'ini doğrular; isim değişmişse kurulumu hata ile durdurur.
12. Servislerin durumunu ve temel health check sonuçlarını gösterir.
13. Dionaea, disk kullanımı ve olay logu için iki dakikada bir health check çalıştırır.

Kurulum sırasında egress karantinası, Avahi kamuflajı ve birincil arayüz seçimi istenir. Egress ve Avahi varsayılan olarak kapalıdır. RFC1918 yönlerine giden Docker trafiği her durumda engellenir.

## Servisler

```bash
systemctl status guardian-core.service
systemctl status guardian-log-archive.timer
docker compose -f /opt/guardian/docker/docker-compose.yml ps
systemctl status guardian-healthcheck.timer
systemctl start guardian-healthcheck.service
```

### Tailscale SOC paneli

Kurulum Tailscale daemon'ını kurar ve etkinleştirir. Kimlik doğrulama için
kurulumdan sonra:

```bash
sudo tailscale up --accept-dns=false
sudo tailscale serve --bg http://127.0.0.1:8767
sudo systemctl start guardian-soc.service
```

Panel yalnızca localhost ve Tailscale adreslerini kabul eder. `8766` mevcut
Guardian API'sidir; SOC login uygulaması `8767` üzerinde çalışır. Üretimde
paneli doğrudan HTTP yerine Tailscale Serve tarafından sağlanan HTTPS URL'siyle
açın. SOC kimlik bilgileri `/etc/guardian/soc.env` içinde tanımlanmalıdır:
`GUARDIAN_SOC_PASSWORD_BCRYPT` bcrypt hash, `GUARDIAN_SOC_TOTP_SECRET` ise
Google Authenticator secret olmalıdır.

### Açılış paket kontrolü

`guardian-package-status.service` her sistem açılışında `apt-get update`
çalıştırır ve yükseltilebilir paket sayısını `PACKAGE_STATUS` olayı olarak
`events.jsonl` dosyasına yazar. Paketleri otomatik yükseltmez; mevcut
`unattended-upgrades` politikası ayrı çalışır. Durumu görmek için:

```bash
systemctl status guardian-package-status.service
journalctl -u guardian-package-status.service --no-pager
```

### Pi 5 performans ve termal koruma

Optimizasyonları root olarak uygulamak için:

```bash
sudo /opt/guardian/scripts/optimize_system.sh
sudo systemctl enable --now guardian-fan.service guardian-throttle.timer
```

Tam kurulum sırasında otomatik uygulamak için:

```bash
sudo RUN_SYSTEM_OPTIMIZATION=1 ./install.sh
```

Fan kontrolü `vcgencmd` ve kernel cooling device üzerinden 0-3 kademelerini
kullanır. `vcgencmd` bulunmayan Ubuntu kurulumlarında fan servisi journal'a hata
yazar; donanım fanı için Raspberry Pi firmware/driver desteği gereklidir.
Throttle kontrolü her dakika `THERMAL_THROTTLE` olayı üretir.

Kurulum tamamlandığında mevcut SSH kullanıcı adı gösterilir; kullanıcı adı veya parola değiştirilmez:

```bash
ssh <kullanıcı>@<RASPBERRY_PI_IP>
```

Canlı dashboard:

```bash
sudo journalctl -u guardian-core.service -f
```

Olay logları `/opt/guardian/logs/active/events.jsonl` altında tutulur.

Auditd HIDS ve yapılandırma yedekleme kurulumu için [Auditd README](ops/auditd/README.md)
ve [config yedekleme README](ops/config-backup/README.md) belgelerine bakın.

Ek modüller: [Cowrie](ops/cowrie/README.md), [günlük anomali](ops/anomaly/README.md),
[SPAN topolojisi](docs/SPAN_TOPOLOJI.md), [tehdit modeli](docs/TEHDIT_MODELI.md) ve
[IDS karşılaştırması](docs/KARSILASTIRMA.md).

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
- Honeypot varsayılan olarak çalışmaz. Dionaea için `HONEYPOT_TYPE=dionaea`, Cowrie için `HONEYPOT_TYPE=cowrie` ile birlikte `/opt/guardian/config/guardian.conf` içinde `HONEYPOT_ENABLED=1` yapıp `systemctl restart guardian-core.service` çalıştırın. İkisini aynı anda çalıştırmayın. Dionaea, host SSH ile çakışmaması için hostta 2224/2323 portlarını kullanır.
- `guardian-system-monitor.service` NTP senkronizasyonunu, disk kullanımını ve journal kernel uyarılarını JSONL olaylarına yazar.
- Olay logu 100 MB'a ulaştığında `.1` dosyasına döndürülür; ayrıca filesystem kullanımı %90'a ulaşırsa health check başarısız olur.
- Egress karantinasını geri almak için `/opt/guardian/network/iptables_rules.sh remove` kullanılabilir.

## Pi 5 işletim özellikleri

### Sıcaklık

`vcgencmd` ile CPU sıcaklığı beş dakikada bir `/var/log/guardian/temperature.log`
dosyasına yazılır. 80°C `WARNING`, 85°C `CRITICAL` olarak kaydedilir:

```bash
systemctl status guardian-temperature.timer
systemctl start guardian-temperature.service
```

### Log2RAM

`/var/log/guardian` 128 MB tmpfs olarak tutulur ve RAM logları saatlik olarak
`/opt/guardian/logs/guardian-ram/latest.tar.gz` dosyasına yazılır. Ayar
`/etc/log2ram.conf` içinde `SIZE=128M` olarak oluşturulur.

### Kaynak sınırları ve watchdog

`guardian-core` için `MemoryMax=300M`, `MemorySwapMax=100M`, `WatchdogSec=60`,
`RuntimeMaxSec=86400` ve otomatik yeniden başlatma aktiftir. Python, her 30 saniyede
watchdog bildirimi gönderir; her beş dakikada `gc.collect()` ve nesne sayısını olay
loguna yazar. Honeypot varsayılan kapalı olduğunda yardımcı servis limitleriyle
Guardian süreçlerinin toplam cgroup bütçesi 400 MB altında tutulur; honeypot
etkinleştirilirse ayrıca 256 MB Docker bütçesi gerekir.

### Ağ arayüzü geçişi

NetworkManager dispatcher; Ethernet/Wi-Fi geçişinde egress kurallarını uygular ve
`guardian-core` servisini yeniden başlatır:

```bash
systemctl status guardian-core.service
```

### SQLite bakımı

Olaylar WAL modunda `/opt/guardian/data/events.db` içinde tutulur. Aylık timer,
183 günden eski kayıtları `/opt/guardian/logs/archive` altındaki arşiv veritabanına
aktarır ve ardından `VACUUM` çalıştırır:

```bash
systemctl status guardian-sqlite-maintenance.timer
systemctl start guardian-sqlite-maintenance.service
```

### Güvenlik güncellemeleri

`unattended-upgrades` yalnızca Ubuntu güvenlik deposunu kullanır, otomatik yeniden
başlatmayı kapalı tutar ve güncelleme olaylarını syslog/journald'a yazar.

### Yerel health API

Flask servisi yalnızca `127.0.0.1:8766` üzerinde `/health` endpoint'i sunar:

```bash
systemctl status guardian-web.service
curl http://127.0.0.1:8766/health
```

Korunan API uçları için `/etc/guardian/web.env` içindeki token `Bearer` şemasıyla
gönderilmelidir:

```bash
curl -H "Authorization: Bearer ${GUARDIAN_API_TOKEN}" \
  http://127.0.0.1:8766/api/stats
```

API çağrılarında `/etc/guardian/web.env` içindeki gerçek değer kullanılmalıdır:

```bash
TOKEN="$(sudo awk -F= '$1 == "GUARDIAN_API_TOKEN" {print $2}' /etc/guardian/web.env)"
curl -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:8766/api/stats
```

Not: Belgede kalan eski token gösterimleri kullanılmamalıdır; API yalnızca
`Bearer` şemasındaki gerçek `GUARDIAN_API_TOKEN` değerini kabul eder.

## Modül 2: Tespit motoru

Tespitler `DETECTOR_*` ayarlarıyla bağımsız açılıp kapatılır:

- `DETECTOR_ARP_SPOOF`: ARP IP/MAC değişimleri
- `DETECTOR_ROGUE_DHCP`: `TRUSTED_DHCP_SERVERS` dışındaki DHCP sunucuları
- `DETECTOR_DNS`: uzun DNS etiketleri ve çelişkili DNS cevapları
- `DETECTOR_ICMP`: yüksek hacimli ICMP payload göstergeleri
- `DETECTOR_SLOW_PORT_SCAN`: 15 dakikaya yayılan port taramaları
- `DETECTOR_NEW_DEVICE`: yeni kaynak MAC adresleri
- `DETECTOR_MAC_FLOODING`: kısa sürede yüksek sayıda MAC adresi
- `DETECTOR_THREAT_INTEL`: yerel IP blocklist eşleşmeleri

Örnek:

```ini
DETECTOR_ARP_SPOOF=1
DETECTOR_DNS=1
TRUSTED_DHCP_SERVERS=192.168.1.1
THREAT_INTEL_BLOCKLIST=/opt/guardian/config/blocklist.txt
```

Blocklist dosyası satır başına bir IP alır; internetten otomatik çekilmez ve
operatör tarafından doğrulanmış kaynaklarla güncellenmelidir. Detector hatası
çekirdek sniff döngüsünü durdurmaz; `detector_error` olayı yazılır.

Test:

```bash
python -m unittest discover -s tests
```

## Modül 3: Veri katmanı

SQLite WAL veritabanı `/opt/guardian/data/events.db` altında tutulur.
Olaylar JSONL ile birlikte `severity` ve `group_key` alanlarıyla saklanır.
Veri katmanı şu işlemleri sağlar:

- Sayfalı olay sorgulama
- Öncelik ve olay türü istatistikleri
- CSV dışa aktarma
- SQLite WAL ve busy timeout
- Aylık eski kayıt arşivi ve `VACUUM`

## Modül 5: Web API

Web servisi ayrı çalışır ve yalnızca `127.0.0.1:8766` adresine bağlanır:

```bash
systemctl status guardian-web.service
curl http://127.0.0.1:8766/health
```

Korunan endpoint'ler için kurulum sırasında `/etc/guardian/web.env` içinde
rastgele bir bearer token oluşturulur:

```bash
TOKEN="$(sudo awk -F= '{print $2}' /etc/guardian/web.env)"
curl -H "Authorization: Bearer ${TOKEN}" \
  "http://127.0.0.1:8766/api/events?limit=50"
curl -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:8766/api/stats
curl -H "Authorization: Bearer ${TOKEN}" \
  http://127.0.0.1:8766/api/events.csv
```

`/health` kimlik doğrulaması istemez, olay ve istatistik endpoint'leri ister.
Token dosyası root sahibi ve `guardian` grubuna okunabilir olarak oluşturulur.

Egress kuralları Docker'ın `DOCKER-USER` zincirinde uygulanır. Mevcut host firewall kuralları silinmez. İkincil arayüz bağlandığında, `PRIMARY_INTERFACE` seçilmişse o arayüzdeki default route kaldırılır; bu nedenle kurulum sırasında yönetim bağlantısının birincil arayüzünü doğru seçin.

## Geliştirme

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
python -m unittest discover -s tests
```
