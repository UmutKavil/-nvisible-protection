# Auditd HIDS

Bu modül auditd kayıtlarını takip ederek kritik dosya değişikliklerini, root
olarak çalıştırılan kullanıcı süreçlerini ve `sudo`, `su`, `pkexec` kullanımını
`events.jsonl` içine yazar. `guardian-core` işleminden bağımsızdır.

Ubuntu 24.04'te kurulum için root olarak `sudo apt install auditd audispd-plugins`
çalıştırın. Mevcut audit kurallarını silmeden
`/etc/audit/rules.d/guardian.rules` dosyasını kopyalayın, ardından
`sudo augenrules --load` ve `sudo systemctl enable --now guardian-audit-parser.service`
çalıştırın. Paket kurulu değilse parser servisi başlatılmamalıdır.

Olay tipleri `AUDIT_FILE_CHANGE`, `AUDIT_ROOT_EXEC` ve `AUDIT_PRIV_ESC` olarak
yazılır. Manuel test: `sudo python3 /opt/guardian/scripts/audit_parser.py --once`.
Kuralların yüklendiğini `sudo auditctl -l | grep guardian_` ile doğrulayın.
