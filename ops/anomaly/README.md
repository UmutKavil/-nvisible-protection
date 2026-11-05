# Günlük anomali istatistiği

`anomaly_daily.py`, SQLite olaylarını son 24 saat ve önceki 7 günlük baseline
ile karşılaştırır. Olay tipindeki üç kat artış, yeni olay tipi ve 02:00-05:00
arasındaki beklenmeyen aktivite ayrı JSONL olayları olarak yazılır.

Servis bağımsızdır; hata vermesi `guardian-core` sürecini durdurmaz.

Kurulum ve test:

```bash
sudo systemctl enable --now guardian-anomaly.timer
sudo systemctl start guardian-anomaly.service
cat /opt/guardian/logs/anomaly/$(date +%F).json
```

Pandas sanal ortamda bulunmalıdır. Kurulumda:
`/opt/guardian/venv/bin/pip install -r /opt/guardian/requirements-anomaly.txt`.
