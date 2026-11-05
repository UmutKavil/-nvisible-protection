# Cowrie honeypot

Cowrie, SSH ve Telnet etkileşimlerini 2222 ve 2223 portlarında kaydeder.
TTY replay açıktır; komutlar `/opt/guardian/cowrie/tty` altında tutulur.
Container Docker socket'i kullanmaz, root olarak çalıştırılmaz, 256 MB RAM ve
1 CPU ile sınırlıdır.

Etkinleştirmek için:

```ini
HONEYPOT_ENABLED=1
HONEYPOT_TYPE=cowrie
```

Ardından:

```bash
sudo systemctl enable --now guardian-cowrie.service guardian-cowrie-parser.service
sudo docker compose -f /opt/guardian/docker/cowrie/docker-compose.yml ps
```

Cowrie imajı `linux/arm64` manifestiyle yayınlanır. Dionaea ile aynı anda
çalıştırmayın; `HONEYPOT_TYPE` yalnızca `cowrie` veya `dionaea` olmalıdır.
Egress karantinası Docker `DOCKER-USER` zincirindeki Guardian kurallarıyla
uygulanır.

Test:

```bash
python3 /opt/guardian/scripts/cowrie_log_parser.py --once
ss -lnt | grep -E ':2222|:2223'
```
