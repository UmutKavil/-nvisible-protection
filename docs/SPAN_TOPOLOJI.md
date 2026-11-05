# SPAN Topolojisi

```text
İnternet
   |
[Router/Gateway]
   |
[Managed Switch] ----(SPAN / mirror destination)---- [Raspberry Pi 5 eth0]
   |                                                       |
   +---- istemci, sunucu ve IoT portları                    +-- Guardian
```

SPAN, seçilen switch portu veya VLAN trafiğinin kopyasını hedef porta gönderir.
Pi bu konumda yönlendirici değildir; kopyalanan paketleri dinler. Hedef port
normal erişim portu gibi kullanılmamalı ve yönetim erişimi ayrı arayüz/VLAN
üzerinden yapılmalıdır.

Örnekler:

```text
Cisco IOS:    monitor session 1 source interface Gi1/0/1 - 4 both
              monitor session 1 destination interface Gi1/0/24
TP-Link:      Port Mirroring > Mirroring Port: 24, Mirrored Ports: 1-4
MikroTik:     /interface ethernet switch rule
              (model dokümanındaki mirror-source/mirror-target seçenekleri)
```

SPAN ile kaynak port/VLAN'dan geçen unicast, broadcast ve multicast kopyaları
görülebilir. Mirror yapılandırmasına dahil olmayan VLAN'lar, switch içindeki
portlar arası trafik ve şifreli yük içeriği görülemez. Oversubscription ve NIC
kapasitesi paket kaybına neden olabilir.

Pi'yi gateway veya inline bridge yapmak transit görünürlüğünü artırır; fakat
tek arıza noktası ve daha karmaşık yönlendirme/firewall oluşturur. SPAN gözlem
amaçlı daha düşük riskli seçenektir.

```bash
sudo tcpdump -i eth0 -c 10
```

Paket görünmüyorsa switch kaynak/hedef portlarını, VLAN'ı, promiscuous modu ve
Pi'nin doğru arayüzünü kontrol edin.
