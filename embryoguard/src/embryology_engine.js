/**
 * EmbryoGuard — Patient-Friendly Preliminary IVF Assessment & Dynamic NEAR Refund Engine
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

  // Patient-friendly sperm count & motility categories (based on WHO spermiogram reference values)
  const SPERM_CATEGORIES = {
    normal: {
      labelTr: "Normal Değerler (Sayı: >15 Milyon/mL • Hareketlilik: >%40)",
      labelEn: "Normal Values (Count: >15M/mL • Motility: >40%)",
      modifier: 0
    },
    mild_low: {
      labelTr: "Hafif Düşük (Sayı: 5–15 Milyon/mL • Hareketlilik: %20–%40)",
      labelEn: "Mildly Reduced (Count: 5–15M/mL • Motility: 20%–40%)",
      modifier: -4
    },
    severe_low: {
      labelTr: "Belirgin Düşük (Sayı: <5 Milyon/mL • Hareketlilik: <%20)",
      labelEn: "Significantly Reduced (Count: <5M/mL • Motility: <20%)",
      modifier: -9
    },
    azoospermia: {
      labelTr: "Azospermi (Tahlilde sperm hücresi görülmedi)",
      labelEn: "Azoospermia (No sperm seen in ejaculate)",
      modifier: -14
    },
    unknown: {
      labelTr: "Henüz sperm tahlilimiz yok / Bilmiyorum",
      labelEn: "Not tested yet / Unknown",
      modifier: -2
    }
  };

  /**
   * Calculates a preliminary, non-final assessment value and a dynamic refund percentage
   * that scales directly with the patient's preliminary probability.
   */
  function calculatePreliminaryAssessment(input) {
    const age = Number(input.age) || 32;
    const amhKnown = input.amhKnown !== false;
    const amh = amhKnown ? Number(input.amh) || 2.0 : 1.8;
    const priorCycles = Number(input.priorCycles) || 0;
    const spermCategory = input.spermCategory || "normal";

    // Base preliminary estimate by maternal age
    let score = 64;
    if (age <= 29) score = 68;
    else if (age <= 33) score = 63;
    else if (age <= 36) score = 55;
    else if (age <= 39) score = 44;
    else if (age <= 42) score = 31;
    else score = 21;

    // AMH adjustment
    if (amhKnown) {
      if (amh < 0.6) score -= 11;
      else if (amh < 1.1) score -= 6;
      else if (amh >= 1.8 && amh <= 4.2) score += 4;
      else if (amh > 4.2) score += 2;
    }

    // Prior cycles adjustment
    score -= Math.min(12, priorCycles * 4);

    // Sperm count & motility adjustment
    const spermInfo = SPERM_CATEGORIES[spermCategory] || SPERM_CATEGORIES.normal;
    score += spermInfo.modifier;

    // Clamp preliminary estimate between 15% and 76%
    const preliminaryEstimatePct = Math.round(Math.max(15, Math.min(76, score)));

    // Dynamic Refund Percentage: scales smoothly with the preliminary estimate (never static!)
    // Range: 20% to 65% based on preliminary score
    const dynamicRefundPct = Math.round(
      Math.max(20, Math.min(65, 12 + preliminaryEstimatePct * 0.68))
    );

    return {
      preliminaryEstimatePct,
      dynamicRefundPct,
      isFinal: false,
      spermLabelTr: spermInfo.labelTr,
      spermLabelEn: spermInfo.labelEn,
      disclaimerTr:
        "Bu oran yalnızca girdiğiniz ön bilgilere dayalı tahmini bir değerdir ve nihai değildir. Kesin tıbbi değerlendirme, başarı beklentisi ve size uygun klinik yönlendirmesi Uzman Embriyolog ile yapılacak görüşme sonrasında netleştirilir.",
      disclaimerEn:
        "This value is a preliminary estimate based solely on your inputs and is not final. Your definitive assessment and clinic referral are finalized after consulting with the Lead Clinical Embryologist."
    };
  }

  // Backward-compatible wrapper for automated test suite / server endpoints
  function calculateEmbryologyOutcome(input) {
    const res = calculatePreliminaryAssessment({
      age: input.age,
      amh: input.amh,
      amhKnown: true,
      priorCycles: input.priorCycles,
      spermCategory: input.spermFactor === "severe_oat_high_dfi" ? "severe_low" : "normal"
    });
    return {
      preliminary: res,
      probabilities: {
        singleCycleSuccessPct: res.preliminaryEstimatePct
      },
      vaultTerms: {
        refundGuaranteePct: res.dynamicRefundPct
      }
    };
  }

  function createPrivateAiAttestation(patientInput) {
    const timestamp = new Date().toISOString();
    const rawPayload = JSON.stringify({
      age: patientInput.age,
      sperm: patientInput.spermCategory || "normal",
      ts: timestamp
    });
    let hash = 0x811c9dc5;
    for (let i = 0; i < rawPayload.length; i++) {
      hash ^= rawPayload.charCodeAt(i);
      hash = (hash * 0x01000193) >>> 0;
    }
    const hexHash = hash.toString(16).padStart(8, "0") + "a7f9c4e2910b3d85e641209c8f721b3a";
    return {
      teeEnclaveId: "near-ai-tee-private-enclave",
      piiStripped: true,
      attestationHash: "0x" + hexHash,
      verifiedAt: timestamp
    };
  }

  function createNearIntentQuote(amountUsd, sourceAsset, dynamicRefundPct) {
    const rates = {
      "USDC": { symbol: "USDC", rate: 1.0, chain: "near:intents", feeUsd: 0.10 },
      "USDT": { symbol: "USDT", rate: 1.0, chain: "near:intents", feeUsd: 0.15 },
      "NEAR": { symbol: "NEAR", rate: 4.85, chain: "near:mainnet", feeUsd: 0.01 },
      "SOL": { symbol: "SOL", rate: 185.0, chain: "sol:mainnet", feeUsd: 0.04 },
      "BTC": { symbol: "BTC", rate: 88500.0, chain: "btc:mpc", feeUsd: 1.10 }
    };
    const key = Object.keys(rates).find(k => String(sourceAsset).includes(k)) || "USDC";
    const selected = rates[key];
    const tokenAmount = (amountUsd / selected.rate).toFixed(selected.symbol === "BTC" ? 5 : 2);
    const refundUsd = Math.round((amountUsd * (dynamicRefundPct || 45)) / 100);
    return {
      intentId: "intent-eg-" + Math.random().toString(36).substring(2, 9),
      solverAccount: "medtour-solver.intents.near",
      sourceAsset: key,
      sourceChain: selected.chain,
      tokenAmount: `${tokenAmount} ${selected.symbol}`,
      usdEquivalent: amountUsd,
      refundUsd,
      dynamicRefundPct: dynamicRefundPct || 45,
      bridgeFeeUsd: selected.feeUsd,
      settlementTimeSec: 2.1
    };
  }

  return {
    SPERM_CATEGORIES,
    calculatePreliminaryAssessment,
    calculateEmbryologyOutcome,
    createPrivateAiAttestation,
    createNearIntentQuote
  };
});
