# Guardian ve IDS/NSM karşılaştırması

| Özellik | Guardian | Snort | Suricata | Zeek |
|---|---|---|---|---|
| Kurulum kolaylığı | Pi odaklı, tek repo | Kural/servis kurulumu | Orta/karmaşık | Orta/karmaşık |
| RAM kullanımı | Düşük, sınırlandırılmış | Düşük-orta | Orta-yüksek | Orta-yüksek |
| Pi 5 uyumu | Optimize edilmiş | Yüke bağlı uygun | ARM64 mevcut, kaynak ister | ARM64 mümkün, kaynak ister |
| Kural tabanlı tespit | Sınırlı | Güçlü imza kuralları | Çok güçlü imza kuralları | Script/politika tabanlı |
| Anomali tespiti | Basit eşik/baseline | Kural/eklenti ile | Kural/eklenti ile | Zengin protokol analizi |
| Honeypot entegrasyonu | Cowrie/Dionaea entegre | Harici | Harici | Harici |
| Web arayüzü | Basit yerel API | Harici araçlar | Harici araçlar | Harici ekosistem |
| Topluluk desteği | Küçük | Büyük | Büyük | Büyük |
| Lisans | Proje lisansına bağlı | GPLv2 | GPLv2 | BSD |

Guardian'ın farkı Raspberry Pi için hafif çalışması, Türkçe dokümantasyon ve
honeypot ile HIDS'i tek operasyon akışında birleştirmesidir. Eksikleri imza
tabanlı tespit motorunun olmaması, büyük ölçekli ağlara uygun olmaması ve küçük
topluluk desteğidir.

Küçük lab, ev/ofis veya düşük kaynaklı Pi gözlem noktası için Guardian uygundur.
Kurumsal ağda yüksek throughput, olgun imza setleri ve merkezi operasyon
gerekiyorsa Suricata; metadata ve protokol analizi gerekiyorsa Zeek tercih
edilmelidir. Guardian bu araçların yerine değil, tamamlayıcı hafif bir katman
olarak kullanılabilir.
