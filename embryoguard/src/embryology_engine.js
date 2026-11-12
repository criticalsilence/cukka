/**
 * EmbryoGuard — Clinical Embryology Actuarial Engine, Private AI TEE Anonymizer & NEAR Intents Quote Engine
 * Authored for NEAR Hackathon 2026
 */

(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.EmbryoGuardEngine = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  // Gardner Blastocyst Grading multipliers based on clinical embryology literature
  const GARDNER_MULTIPLIERS = {
    "5AA": { factor: 1.24, label: "Hatching Blastocyst (5AA) — En Yüksek İmplantasyon Potansiyeli", euploidEst: 0.68 },
    "4AA": { factor: 1.18, label: "Expanded Blastocyst (4AA) — Mükemmel ICM & Trofektoderm", euploidEst: 0.64 },
    "4AB": { factor: 1.10, label: "Expanded Blastocyst (4AB) — Güçlü İç Hücre Kitlesi", euploidEst: 0.58 },
    "3BB": { factor: 0.96, label: "Full Blastocyst (3BB) — Standart Klinik Kalite", euploidEst: 0.49 },
    "2BC": { factor: 0.74, label: "Early/Cavitating Blastocyst (2BC) — Yakın Takip Gerekli", euploidEst: 0.34 },
    "UNKNOWN": { factor: 1.0, label: "Henüz OPU / Kültür Yapılmadı (Bazal Tahmin)", euploidEst: 0.52 }
  };

  // Partner Clinics curated by the Lead Embryologist
  const PARTNER_CLINICS = [
    {
      id: "IST-EUROFERT-01",
      name: "Bosphorus ART & Advanced Embryology Center",
      location: "İstanbul, Türkiye",
      flag: "🇹🇷",
      nearAccount: "bosphorus-ivf.near",
      accreditation: "ISO 15189 • JCI • ESHRE Certified Lab",
      embryoscopePlus: true,
      blastocystConversionRate: 61, // % (Industry avg: 45-50%)
      vitrificationSurvivalRate: 98.4, // %
      pgtaTurnaroundDays: 7,
      standardPriceUsd: 4200,
      sharedRiskVaultUsd: 5400,
      refundGuaranteePct: 50,
      specialties: ["ICSI + IMSI", "EmbryoScope+ Time-Lapse", "PGT-A NGS", "Microfluidics Sperm Chip", "Piezo-ICSI"],
      embryologistNoteTr: "Düşük AMH ve tekrarlayan implantasyon başarısızlığı (RIF) vakalarında Piezo-ICSI ve Time-Lapse inkübatör altyapısıyla en yüksek 5. gün blastokist dönüşüm oranına sahip anlaşmalı laboratuvarımız.",
      embryologistNoteEn: "Top partner lab for low AMH and recurrent implantation failure (RIF) with Piezo-ICSI and continuous EmbryoScope+ Time-Lapse culture."
    },
    {
      id: "CYP-GENESIS-02",
      name: "Mediterranean Reproductive Genetics & Cryo Hub",
      location: "Girne, Kuzey Kıbrıs",
      flag: "🇨🇾",
      nearAccount: "med-genetics-ivf.near",
      accreditation: "ISO 9001 • Cleanroom Class A (ISO 5)",
      embryoscopePlus: true,
      blastocystConversionRate: 64,
      vitrificationSurvivalRate: 99.1,
      pgtaTurnaroundDays: 6,
      standardPriceUsd: 4800,
      sharedRiskVaultUsd: 6100,
      refundGuaranteePct: 50,
      specialties: ["PGT-A / PGT-M", "Advanced Cryo Vitrification", "38+ Yaş İleri Maternal Yaş Protokolü", "RI Witness RFID Güvenlik"],
      embryologistNoteTr: "RI Witness (elektronik çipli biyolojik materyal takip sistemi) ile %100 laboratuvar şeffaflığı ve ileri yaş genetik tarama (PGT-A) vakalarında yüksek başarı.",
      embryologistNoteEn: "Equipped with RI Witness RFID sample tracking for 100% chain-of-custody transparency and rapid in-house NGS PGT-A."
    },
    {
      id: "PRG-PRAGUEFERT-03",
      name: "Central Europe Reproductive & Immunology Institute",
      location: "Prag, Çekya",
      flag: "🇨🇿",
      nearAccount: "prague-fertility.near",
      accreditation: "EU Tissue Directive 2004/23/EC • ESHRE",
      embryoscopePlus: true,
      blastocystConversionRate: 59,
      vitrificationSurvivalRate: 97.9,
      pgtaTurnaroundDays: 8,
      standardPriceUsd: 5200,
      sharedRiskVaultUsd: 6600,
      refundGuaranteePct: 50,
      specialties: ["Reproductive Immunology", "MACS Sperm Selection", "ERA/ALICE Endometrial Test", "Assisted Hatching (Laser)"],
      embryologistNoteTr: "Avrupa Birliği doku direktiflerine tam uyumlu, özellikle immünolojik faktörlü ve endometriyal reseptivite (ERA) takibi gereken çiftler için ideal.",
      embryologistNoteEn: "Full EU Tissue Directive compliance, ideal for immunological factors and personalized embryo transfer (pET / ERA window)."
    },
    {
      id: "ANT-MEDTOUR-04",
      name: "Riviera IVF & Holistic Fertility Resort Clinic",
      location: "Antalya, Türkiye",
      flag: "🇹🇷",
      nearAccount: "riviera-fertility.near",
      accreditation: "T.C. Sağlık Bakanlığı Uluslararası Sağlık Turizmi Yetki Belgesi • ISO",
      embryoscopePlus: true,
      blastocystConversionRate: 58,
      vitrificationSurvivalRate: 98.0,
      pgtaTurnaroundDays: 7,
      standardPriceUsd: 3900,
      sharedRiskVaultUsd: 4950,
      refundGuaranteePct: 50,
      specialties: ["VIP Medikal Turizm Paketi", "Düşük Stresli Tatil + Tedavi", "Dual Stimulation (DuoStim)", "Mikro-TESE / Androloji"],
      embryologistNoteTr: "Yurt dışından gelen hastalar için konaklama + transfer + DuoStim (aynı siklusta çift yumurta toplama) protokolünde en ekonomik ve şeffaf paket.",
      embryologistNoteEn: "All-inclusive medical tourism logistics combined with DuoStim protocols for poor ovarian responders."
    }
  ];

  /**
   * Calculates transparent oocyte-to-blastocyst funnel & clinical pregnancy probability
   */
  function calculateEmbryologyOutcome(input) {
    const age = Number(input.age) || 33;
    const amh = Number(input.amh) || 2.1; // ng/mL
    const priorCycles = Number(input.priorCycles) || 0;
    const spermFactor = input.spermFactor || "normozoospermia"; // normozoospermia | mild_oligo | severe_oat_high_dfi
    const gardnerGrade = input.gardnerGrade || "4AA";
    const usePgtA = Boolean(input.usePgtA);

    // 1. Estimate Retrieved Oocytes (OPU) from AMH & Age
    let baseOocytes = Math.round(amh * 5.2 + (age < 32 ? 3 : age < 37 ? 1 : -1));
    baseOocytes = Math.max(2, Math.min(24, baseOocytes));

    // 2. Mature Metaphase II (MII) oocytes (~80%)
    const matureMII = Math.max(1, Math.round(baseOocytes * 0.8));

    // 3. Fertilized 2PN via ICSI (~72% - 82% depending on sperm DFI/factor)
    const fertRate =
      spermFactor === "normozoospermia"
        ? 0.80
        : spermFactor === "mild_oligo"
        ? 0.74
        : 0.65;
    const fertilized2PN = Math.max(1, Math.round(matureMII * fertRate));

    // 4. Day-3 Cleavage Embryos (~86% of 2PN)
    const day3Embryos = Math.max(1, Math.round(fertilized2PN * 0.86));

    // 5. Day-5 Usable Blastocysts (~52% of 2PN, adjusted slightly by age)
    const blastRate = age <= 34 ? 0.56 : age <= 38 ? 0.48 : age <= 41 ? 0.39 : 0.28;
    const day5Blastocysts = Math.max(1, Math.round(fertilized2PN * blastRate));

    // 6. Base Clinical Pregnancy / Live Birth Probability per Cycle
    let baseProb = 0.58;
    if (age < 30) baseProb = 0.64;
    else if (age <= 34) baseProb = 0.59;
    else if (age <= 37) baseProb = 0.51;
    else if (age <= 40) baseProb = 0.39;
    else if (age <= 42) baseProb = 0.26;
    else baseProb = 0.16;

    // AMH adjustment
    if (amh < 0.8) baseProb -= 0.08;
    else if (amh < 1.2) baseProb -= 0.04;
    else if (amh >= 2.0 && amh <= 4.5) baseProb += 0.04;

    // Prior failed cycles adjustment
    baseProb -= Math.min(0.12, priorCycles * 0.035);

    // Sperm factor adjustment
    if (spermFactor === "severe_oat_high_dfi") baseProb -= 0.05;

    // Gardner grade adjustment
    const gInfo = GARDNER_MULTIPLIERS[gardnerGrade] || GARDNER_MULTIPLIERS["4AA"];
    let adjustedProb = baseProb * gInfo.factor;

    // PGT-A Euploid transfer boost (especially impactful for age >= 36)
    if (usePgtA) {
      adjustedProb = Math.max(adjustedProb + (age >= 36 ? 0.14 : 0.08), 0.62 * gInfo.factor);
    }

    const finalProbabilityPct = Math.round(Math.max(15, Math.min(82, adjustedProb * 100)));
    const cumulativeTwoCyclePct = Math.round(
      Math.min(94, (1 - Math.pow(1 - finalProbabilityPct / 100, 2)) * 100)
    );

    // Shared-Risk Vault Actuarial Pricing
    // Higher probability = higher refund guarantee sustainable at lower risk premium
    const refundGuaranteePct = finalProbabilityPct >= 50 ? 55 : finalProbabilityPct >= 38 ? 50 : 40;

    return {
      funnel: {
        expectedOocytesOPU: baseOocytes,
        matureMIIOocytes: matureMII,
        fertilized2PN_ICSI: fertilized2PN,
        day3CleavageEmbryos: day3Embryos,
        day5Blastocysts: day5Blastocysts,
        estimatedEuploidBlastocysts: Math.max(1, Math.round(day5Blastocysts * gInfo.euploidEst))
      },
      probabilities: {
        singleCycleSuccessPct: finalProbabilityPct,
        cumulativeTwoCyclePct: cumulativeTwoCyclePct,
        gardnerGradeLabel: gInfo.label
      },
      vaultTerms: {
        refundGuaranteePct: refundGuaranteePct,
        milestone1OpuPct: 20,
        milestone2BlastocystPct: 30,
        milestone3OutcomePct: 50
      }
    };
  }

  /**
   * Simulates NEAR AI Cloud (TEE Private Inference) Anonymization & Attestation
   */
  function createPrivateAiAttestation(patientInput) {
    const timestamp = new Date().toISOString();
    const rawPayload = JSON.stringify({
      ageBracket: patientInput.age <= 34 ? "<=34" : patientInput.age <= 39 ? "35-39" : "40+",
      amhTier: patientInput.amh < 1.0 ? "LOW_DOR" : "NORMAL_RESPONDER",
      gardner: patientInput.gardnerGrade,
      ts: timestamp
    });
    let hash = 0x811c9dc5;
    for (let i = 0; i < rawPayload.length; i++) {
      hash ^= rawPayload.charCodeAt(i);
      hash = (hash * 0x01000193) >>> 0;
    }
    const hexHash = hash.toString(16).padStart(8, "0") + "a7f9c4e2910b3d85e641209c8f721b3a";
    return {
      teeEnclaveId: "near-ai-tee-sgx-h100-enclave-04",
      piiStripped: true,
      attestationHash: "0x" + hexHash,
      verifiedAt: timestamp
    };
  }

  /**
   * Builds a NEAR Intents Cross-Chain Solver Quote for paying or refunding in any asset
   */
  function createNearIntentQuote(amountUsd, sourceAsset) {
    const rates = {
      "USDC (Arbitrum / Base)": { symbol: "USDC", rate: 1.0, chain: "arb:mainnet", feeUsd: 0.12 },
      "USDT (Ethereum / Tron)": { symbol: "USDT", rate: 1.0, chain: "eth:mainnet", feeUsd: 0.25 },
      "NEAR (NEAR Native)": { symbol: "NEAR", rate: 4.85, chain: "near:mainnet", feeUsd: 0.01 },
      "SOL (Solana)": { symbol: "SOL", rate: 185.0, chain: "sol:mainnet", feeUsd: 0.04 },
      "BTC (Chain Signatures MPC)": { symbol: "BTC", rate: 88500.0, chain: "btc:mainnet", feeUsd: 1.20 }
    };
    const selected = rates[sourceAsset] || rates["USDC (Arbitrum / Base)"];
    const tokenAmount = (amountUsd / selected.rate).toFixed(selected.symbol === "BTC" ? 5 : 2);
    return {
      intentId: "intent-eg-" + Math.random().toString(36).substring(2, 9),
      solverAccount: "medtour-solver.intents.near",
      sourceAsset,
      sourceChain: selected.chain,
      tokenAmount: `${tokenAmount} ${selected.symbol}`,
      usdEquivalent: amountUsd,
      bridgeFeeUsd: selected.feeUsd,
      settlementTimeSec: 2.4
    };
  }

  return {
    PARTNER_CLINICS,
    GARDNER_MULTIPLIERS,
    calculateEmbryologyOutcome,
    createPrivateAiAttestation,
    createNearIntentQuote
  };
});
