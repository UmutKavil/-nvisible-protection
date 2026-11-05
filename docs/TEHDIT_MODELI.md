# Guardian Tehdit Modeli

| Saldırı | Detector | Olay Tipi | Savunma |
|---|---|---|---|
| ARP spoofing | `DETECTOR_ARP_SPOOF` | `arp_spoofing` | DAI, segmentasyon |
| Rogue DHCP | `DETECTOR_ROGUE_DHCP` | `rogue_dhcp` | DHCP snooping, güvenilir liste |
| DNS tünelleme | `DETECTOR_DNS` (kısmi) | `dns_anomaly` | DNS proxy, uzunluk/entropy politikası |
| DNS spoofing | `DETECTOR_DNS` (kısmi) | `dns_conflict` | DNSSEC, güvenilir resolver |
| ICMP tünelleme | `DETECTOR_ICMP` (kısmi) | `icmp_anomaly` | Rate ve payload sınırı |
| Hızlı port scan | port scan detector | `port_scan` | Firewall ve rate limit |
| Yavaş port scan | `DETECTOR_SLOW_PORT_SCAN` | `slow_port_scan` | Uzun pencere korelasyonu |
| MAC flooding | `DETECTOR_MAC_FLOODING` | `mac_flooding` | Port security, VLAN |
| Yeni cihaz | `DETECTOR_NEW_DEVICE` | `new_device` | Envanter ve NAC |
| Threat intel eşleşme | `DETECTOR_THREAT_INTEL` | `threat_intel_match` | Doğrulanmış blocklist |
| SSH kaba kuvvet | fail2ban | SSH ban/journal | MFA, anahtar erişimi |
| Yerel yetki yükseltme | Auditd | `AUDIT_PRIV_ESC` | Least privilege, patch |
| Honeypot etkileşimi | Cowrie parser | `COWRIE_LOGIN/COMMAND` | İzole container, egress karantinası |

İlk sekiz ağ davranışı doğru görünürlük ve eşiklerle **evet** veya **kısmen**
yakalanır. DNS/ICMP tünelleme, şifreleme ve düşük hacimli saldırılar derin
protokol/imza analizi olmadığı için kısmi kapsamdadır. Threat intel yalnızca
yerel blocklist kadar günceldir. Auditd ve Cowrie etkin olmalıdır.

Fiziksel saldırı, supply-chain ve imza tabanlı olmayan zero-day saldırıları
kapsam dışıdır. Guardian tam kapsamlı EDR veya IDS/IPS yerine hafif yerel
gözlem ve olay korelasyonu sağlar.
