# Rakip Analizi — Client-Side Agent Memory Infrastructure

> Research snapshot · 16 EYLÜL 2026 · best-effort, canlı + indeks kaynaklar.
> Fatih'in gönderdiği paylaşılan sayfanın (https://muse.ai/s/rakip-analizi-xoxn6lxfm8ylxwxe) tam metni,
> JavaScript render sonrası çıkarılıp aynen korunmuştur.

---

CLİENT-SİDE AJAN HAFIZASI · REKABET TARAMASI

KESİŞİM BOŞ. KOMŞULAR GÜÇLÜ.

On-device kalıcı hafıza, mobil SDK ve sağlık düzeyinde kurumsal sözleşmeyi aynı üründe birleştiren doğrulanmış bir oyuncu bulunamadı. Ama her eksenin yanında ciddi bir alternatif var.

Ana sonuç — ∅ Doğrudan rakip yok; ikame seçenekleri var.
Sunucuda Mem0/Zep. Cihazda Dazzle/Wax. Kurumsal cihaz altyapısında Couchbase Lite.

SNAPSHOT · 16 EYLÜL 2026 | BEST-EFFORT · CANLI + İNDEKS KAYNAKLAR

DÖRT SİNYALDE PAZAR
Tarama, "rakip yok" iddiasını değil, hangi parçaların kimler tarafından sahiplenildiğini test ediyor.
- 0 — Tüm kesişimi karşılayan doğrulanmış vendor
- 3 — Güçlü server/cloud incumbent: Mem0, Zep, Letta
- 3 — Yakın device-side yapı taşı: Dazzle, Wax, velos
- 1 — Kurumsal köprü: Couchbase Lite; hafıza semantiği eksik

REKABET MATRİSİ
Filtrele; sonra hangi oyuncunun teze hangi yönden yaklaştığını karşılaştır.
Rakip filtresi: Tümü | Cihaz odaklı | Kurumsal güçlü | Sunucu odaklı
Rakip yetenek matrisi — OYUNCU | GÖMÜLEBİLİR SDK | CİHAZDA KALICI | MOBİL | ENTERPRİSE | TEZE EN YAKIN YANI

1. Dazzle SDK — #1 · en yakın device şekli | Gömülebilir SDK: Evet | Cihazda kalıcı: Evet; şifreleme doğrulanmadı | Mobil: iOS + Android + Flutter + RN | Enterprise: Yok; OSS beta | Teze en yakın yanı: Cihaz katmanının ürün şekli
2. Couchbase Lite — #2 · ticari yapı taşı | Evet | AES-256 (Enterprise) + vektör arama | iOS + Android | Kurumsal vendor; Lite BAA teyitsiz | Cihaz altyapısı güçlü; ajan hafıza semantiği yok
3. Wax — #3 · iOS-native OSS | Swift Package | Tek dosya; şifreleme belirsiz | Yalnız iOS/macOS | Yok | En iyi iOS-native yapı taşı
4. velos/agentmemory — #4 · Apple-native referans | Swift Package | SQLite + sqlite-vec; şifreleme belirsiz | iOS/macOS/visionOS | Yok; araştırma düzeyi OSS | Zengin hafıza şeması ve eval referansı
5. Mem0 — #5 · enterprise incumbent | Python + Node | Hayır | Yok | SLA, on-prem, SSO | Kurumsal hafıza markası; cihaz hikâyesi yok
6. Zep — #6 · compliance kuvvetli | Python + TS + Go | Hayır | Yok | SLA + BAA beyanı | En net sağlık sözleşmesi hikâyesi
7. Memori — #7 · yeni enterprise giriş | Python + TS | Hayır | Yok | VPC/on-prem; sertifika açık değil | BYODB + veri kontrolü konumlaması
8. Letta — #8 · memory OS yaklaşımı | TypeScript | Hayır | Yok | Uyum iddiası bulunamadı | En güçlü "stateful agent" zihniyeti
9. Reflect Memory — #9 · erken aşama | TypeScript + REST + MCP | Hayır | Yok | SOC 2 sürüyor; V1 BAA yok | Şeffaf ama sağlık için henüz hazır değil

Gösterge açıklaması: Var / güçlü — Kısmi / doğrulanmamış — Yok

OYUNCU PROFİLLERİ
Detayları açarak ürün, dağıtım, uyumluluk ve fiyat sinyalini gör.

Mem0 — En güçlü görünür enterprise posture; tamamen server/cloud ağırlıklı.
- DAĞITIM: Managed cloud, OSS library, self-hosted Docker server. "Local", kullanıcının telefonu değil kendi sunucun.
- UYUM: Resmî fiyat sayfasında "HIPAA Ready", "SOC 2 Type I", "GDPR Ready". Enterprise: SLA, on-prem, audit logs, SSO.
- FİYAT: Ücretsiz → $19/ay → $249/ay → Enterprise özel.
- KRİTİK AÇIK: iOS/Android SDK ve cihazda kalıcı hafıza yok.
- KAYNAK: Resmî fiyatlandırma · SDK changelog — verified live, 2026-09-16

Zep — Sağlık açısından en net BAA hikâyesi; kaynak kalitesi daha zayıf.
- DAĞITIM: Managed cloud; Enterprise'ta BYOK ve BYOC. Graphiti OSS olarak self-host edilebilir.
- UYUM: İndeks kaynaklarında SLA, SOC 2 Type II materyalleri, HIPAA BAA, bir yıllık audit/API logları.
- FİYAT: Ücretsiz → $125/ay → $375/ay → Enterprise özel.
- KRİTİK AÇIK: Mobil SDK ve cihazda hafıza yok. Bu taramada resmî Zep dokümanı canlı okunmadı.
- KAYNAK: Fiyat/enterprise özeti · Framework karşılaştırması — index, doğrudan teyit gerekli

Letta — Memory OS ve stateful-agent yaklaşımı güçlü; compliance sessiz.
- DAĞITIM: Letta Cloud + Apache 2.0 self-hosted Docker. MemFS, git-backed memory'yi agent'ın çalıştığı makineye yansıtır.
- SDK: TypeScript Agent SDK; deneysel Python/TS memory SDK. Mobil değil.
- UYUM: İncelenen dokümanlarda SOC 2, HIPAA, BAA veya SLA iddiası bulunamadı.
- FİYAT: Self-host ücretsiz; Cloud $20–$200/ay; API tabanı $20/ay + kullanım.
- KAYNAK: Resmî doküman · Teams — verified live, compliance açık soru

Dazzle SDK — Tezin cihaz şekline en yakın teknik aday; henüz şirket değil.
- DAĞITIM: Android, iOS, Flutter, React Native ve .NET için embedded on-device agent database.
- SÜRÜM: v1.0.0-beta.5; Maven Central ve Swift Package dağıtımı raporlandı.
- UYUM: Tek-maintainer OSS beta; SLA, SOC 2, HIPAA ve BAA yok. Şifreleme doğrulanmadı.
- ANLAMI: Cihaz katmanının teknik olarak yapılabilir olduğuna kanıt; bugün ticari rakip değil.
- KAYNAK: Tarama raporunda tam, doğrulanmış kamu URL'si elde edilemedi; bu nedenle bağlantı verilmedi. (index, beta)

Wax — Swift-native, tek dosyalı on-device memory engine.
- TEKNİK: Append-only WAL, BM25 + HNSW, on-device MiniLM embeddings, Metal acceleration ve token budgets.
- MOBİL: Swift Package ile iOS/macOS. Android desteği yok.
- UYUM: Saf OSS. Şifreleme, SLA, SOC 2 ve HIPAA dokümante edilmedi.
- ANLAMI: iOS hafıza motoru için güçlü yapı taşı; enterprise ürün değil.
- KAYNAK: Canonical Wax dokümanı — index, Swift 6

velos/agentmemory — Apple platformlarında zengin hafıza şeması sunan araştırma düzeyi OSS.
- TEKNİK: SQLite + embedded sqlite-vec; profil, olgu, karar, taahhüt, epizot, prosedür ve handoff türleri.
- MOBİL: Swift Package ile iOS, macOS ve visionOS; isteğe bağlı Apple Intelligence query expansion/reranking.
- UYUM: Şifreleme doğrulanmadı; SLA, SOC 2, HIPAA veya BAA yok.
- ANLAMI: Ürün değil; hafıza şeması ve eval yaklaşımı açısından iyi bir referans tasarım.
- KAYNAK: GitHub deposu — index, research-grade

Couchbase Lite — En ciddi build-vs-buy alternatifi; sağlık uygunluğu ayrıca doğrulanmalı.
- TEKNİK: Embedded NoSQL, on-device ANN + hybrid arama, AES-256 database encryption, P2P ve cloud sync, conflict resolution.
- MOBİL: iOS, Android, desktop ve IoT SDK'ları.
- UYUM: AES-256 veritabanı şifrelemesi Enterprise Edition özelliği. Couchbase Lite özelinde BAA bu taramada doğrulanmadı.
- KRİTİK AÇIK: Fact extraction, consolidation, temporal facts ve token-budgeted recall gibi ajan-hafıza semantiği yok; sağlık sözleşmesi ayrıca teyit edilmeli.
- KAYNAK: Couchbase Mobile · Mobile datasheet — index, adjacent

PAZARIN KATMANLARI
- Server memory: Mem0 · Zep · Letta · Memori · Reflect
- Boş ürün katmanı: Encrypted on-device memory semantics + mobile SDK + BAA/SLA
- Device storage & sync: Couchbase Lite · MindooDB
- On-device runtimes: llama.cpp ekosistemi · Luxand

Teze yönelik saldırı yüzeyi:
- YÜKSEK — Statüko yeterince iyi olabilir. BAA'lı server memory, alıcının bugün çözüm saydığı seçenek. Boş pazar talep yokluğu da olabilir.
- YÜKSEK — Couchbase üzerinde kendin yap. Güçlü bir alıcı, storage/sync katmanını alıp hafıza semantiğini içeride kurabilir.
- ORTA — Dazzle ürünleşebilir. Device-shaped OSS aday, enterprise ekip ve uyum katmanı kazanırsa doğrudan yaklaşır.
- ORTA — Incumbent mobil SDK ekleyebilir. Mem0 veya Zep'in dağıtımı güçlü; ancak server kökenli mimariyi cihaza taşımak sıradan bir özellik ekleme işi değil.

STRATEJİK SONUÇ
Tez ayakta; iddia daha keskin olmalı.
"Rakip yok" yerine: "Doğrulanmış hiçbir vendor, mobil gömülebilirlik + şifreli cihaz hafızası + sağlık düzeyinde enterprise sözleşmeyi birleştirmiyor."
En yakın ikame Couchbase Lite üzerine in-house memory engine kurmak; en yakın doğrudan teknik sinyal Dazzle.

DOĞRULANACAK BİR SONRAKİ ŞEY
Müşteri, bu mimari için "Couchbase + kendimiz yaparız" yerine para öder mi?

KAYNAKLAR VE SINIRLAR
Bağlantılar araştırma raporundaki tam URL'lerden alınmıştır. Linkler: Mem0 — resmî fiyatlandırma; Mem0 — SDK changelog; Mem0 — GitHub; Letta — resmî doküman; Letta — Teams; Zep — fiyat/enterprise özeti; Memori — GitHub; Reflect — security & compliance; velos/agentmemory — GitHub; Couchbase Mobile; Couchbase Mobile datasheet; Luxand LLM SDK.

Sınırlar: Bu tarama kapsamlı olmaya çalışır ama exhaustive değildir. Zep ve bazı küçük oyuncular yalnız web indeks kaynaklarıyla incelendi. Stealth girişimler, İngilizce dışı kaynaklar, CoreAgent, ownmem, PowerSync, Apple Foundation Models ve Google AICore kapsam dışı veya açık soru kaldı. Mem0'nun resmî sayfası SOC 2 Type I derken üçüncü taraf kaynaklar Type II diyor; burada resmî iddia esas alındı. "Bulunamadı", "yoktur" anlamına gelmez.

RESEARCH SNAPSHOT · 2026-09-16 · CLIENT-SIDE AGENT MEMORY INFRASTRUCTURE
