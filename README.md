# CUKKA — Yalın Kripto Portföy Kasası (V1)

Kripto bilmeyen kullanıcıların e-posta veya Google ile giriş yapıp, Base ağındaki **non-custodial** ortak portföy kasasına (`CukkaVault`) USDC yatırabildiği, yöneticinin yalnızca beyaz listedeki varlıklar arasında sınırlandırılmış swap yapabildiği ve nakit tamponun **Base Earn (Morpho)** kasasında değerlendirildiği davetiyeli portföy uygulaması.

> **"Paran yöneticinin cüzdanında değil, akıllı kontratta durur."**

---

## Mimari Diyagram

```mermaid
flowchart TB
    subgraph Client["İstemci Katmanı (Next.js App Router - Mobil Öncelikli)"]
        UI["Kullanıcı Arayüzü (Türkçe, Jargonsuz)\nGiriş / Dashboard / Ayrıntılar / Para Yükle / Çekim"]
        AdminUI["Admin Paneli (/admin)\nGenel Bakış / Dağılım / Beyaz Liste / Çekim Kuyruğu"]
    end

    subgraph AuthAA["Hesap Soyutlama & Sponsorlu İşlemler"]
        Privy["Privy Giriş (E-posta OTP / Google / Passkey)"]
        SmartAcct["ERC-4337 Akıllı Hesap\n(Approve + Deposit Tek İşlem)"]
        Paymaster["CDP / Pimlico Paymaster\n(%100 Sponsorlu Gas)"]
    end

    subgraph BaseChain["Base Ağı (Base Sepolia -> Base Mainnet)"]
        Vault["CukkaVault.sol\n(Soulbound cukkaSHARE)"]
        Morpho["Base Earn (Morpho ERC-4626)\nNakit Tamponu"]
        Agg["0x / Odos Agregatörü\nBeyaz Liste Swap"]
        CL["Chainlink Fiyat Beslemeleri\n(USDC/USD, ETH/USD, TRY/USD)"]
        DEX["Aero & Uniswap V3\n30dk TWAP & Likidite"]
    end

    subgraph Backend["Arka Uç & İndeksleme"]
        Ponder["Ponder İndeksleyici\n(Kontrat Olayları & Transferler)"]
        Worker["Fiyat, Likidite Kesintisi & NAV Worker\n(5 dk Döngü + Swap Simülasyonu)"]
        DB[("Supabase Postgres\n(Önbellek, Davet Kodları, NAV Raporları)")]
    end

    UI --> Privy --> SmartAcct --> Paymaster --> Vault
    AdminUI --> Vault
    Vault <--> Morpho
    Vault <--> Agg
    Worker --> BaseChain
    Worker -->|"updateNAV(realisticNAV, reportHash)"| Vault
    Worker --> DB
    Ponder --> BaseChain
    Ponder --> DB
```

---

## Proje Fazları

- [x] **Faz 0 — Netleştirme:** Teknik tasarım dokümanı ([`docs/TECHNICAL_DESIGN.md`](docs/TECHNICAL_DESIGN.md)), Türkiye cüzdan karşılaştırması ve 7 mimari kararın onaylanması.
- [x] **Faz 1 — Kontratlar (Yerel Derleme, Test & Kapsam Tamamlandı / Base Sepolia Yayın Adımı):**
  - [`contracts/src/CukkaVault.sol`](contracts/src/CukkaVault.sol): Soulbound `cukkaSHARE`, HWM performans ücreti kristalizasyonu, 24s timelock'lu beyaz liste, slippage / pozisyon üst sınırı / nakit tamponu / günlük swap hacmi korumaları, `±20%` NAV devre kesici, `Pausable` çekim garantisi.
  - [`contracts/test/CukkaVault.t.sol`](contracts/test/CukkaVault.t.sol): 13 test senaryosu + 1.000 koşulu Fuzz testi (**%95.68 Satır Kapsamı, %100 Fonksiyon Kapsamı**).
- [ ] **Faz 2 — Backend:** Ponder indeksleyici, 5 dakikalık Fiyat/Likidite Kesintisi/NAV worker, rebalance simülatörü ve çekim kuyruğu API'si.
- [ ] **Faz 3 — Kullanıcı Arayüzü:** Davet kodlu giriş, Dashboard, Ayrıntılar, Para Yükle (Türk borsaları rehberi + QR + Kartla Yükle) ve Çekim ekranları.
- [ ] **Faz 4 — Admin Paneli:** `/admin` yönetim ve simülasyon arayüzü.
- [ ] **Faz 5 — Sertleştirme:** Slither + Aderyn statik analiz, uç durum testleri ve Base Mainnet geçiş planı.

---

## Faz 1 Test & Kapsam Raporu

| Dosya | Satır Kapsamı (% Lines) | İfade Kapsamı (% Statements) | Fonksiyon Kapsamı (% Funcs) | Durum |
| :--- | :---: | :---: | :---: | :---: |
| `src/CukkaVault.sol` | **%95.68 (310/324)** | **%89.68 (391/436)** | **%100.00 (33/33)** | ✅ Geçti (13/13 Test + 1000 Fuzz) |

---

## Tek Komutla Kurulum ve Test

```bash
# Kontratları derle ve tüm birim + fuzz testlerini çalıştır
npm test

# Kapsam (coverage) raporunu üret
npm run contracts:coverage

# Base Sepolia ağına dağıt ve doğrula
npm run contracts:deploy:sepolia
```
