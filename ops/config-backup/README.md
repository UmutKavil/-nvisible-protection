# Config yedekleme ve doğrulama

`config_check.py`, çekirdek başlamadan önce zorunlu ayarları ve boolean
değerlerini kontrol eder. `config_backup.sh` config dizinini ayrı bir Git
deposunda snapshot'lar; değişiklik yoksa commit oluşturmaz. Pazar günleri
gzip arşivi oluşturulur ve 28 günden eski arşivler temizlenir.

Test:
`GUARDIAN_CONFIG_DIR=/tmp/guardian-config GUARDIAN_BACKUP_DIR=/tmp/guardian-backups
/opt/guardian/scripts/config_backup.sh`
