/**
 * CUKKA V1 — Rebalance Executor & Honeypot / Transfer-Tax Simulator
 *
 * 1. Computes delta between current token weights and admin target weights.
 * 2. Fetches route & calldata from 0x / Odos aggregator.
 * 3. Simulates each swap via eth_call before execution.
 * 4. Honeypot / Tax Guard: Rejects swap and flags token if simulated output < 97% of quoted output.
 * 5. Enforces mandatory Turkish rationale note (gerekçe notu) shown to users in the Details screen.
 */

export interface TargetWeightInput {
  tokenAddress: string;
  symbol: string;
  targetBps: number; // e.g. 1000 = 10%
}

export interface SwapSimulationPreview {
  tokenIn: string;
  tokenOut: string;
  symbolIn: string;
  symbolOut: string;
  amountInUsdc: number;
  quotedOut: number;
  simulatedOut: number;
  effectiveRatioPct: number;
  priceImpactPct: number;
  isHoneypotOrTaxFlagged: boolean;
  statusMessageTr: string;
}

export function validateRebalanceProposal(
  targets: TargetWeightInput[],
  rationaleNoteTr: string,
  minCashBufferBps = 1000
): { valid: boolean; errorTr?: string } {
  if (!rationaleNoteTr || rationaleNoteTr.trim().length < 10) {
    return {
      valid: false,
      errorTr: "Kullanıcılara gösterilecek gerekçe notu zorunludur (en az 10 karakter).",
    };
  }

  const totalBps = targets.reduce((acc, t) => acc + t.targetBps, 0);
  if (totalBps !== 10000) {
    return {
      valid: false,
      errorTr: `Hedef dağılım toplamı %100 (10000 bps) olmalıdır (Mevcut: %${(totalBps / 100).toFixed(2)}).`,
    };
  }

  const usdcTarget = targets.find((t) => t.symbol === "USDC");
  if (!usdcTarget || usdcTarget.targetBps < minCashBufferBps) {
    return {
      valid: false,
      errorTr: `Nakit tamponu (USDC) en az %${(minCashBufferBps / 100).toFixed(1)} olmalıdır.`,
    };
  }

  return { valid: true };
}

/**
 * Checks whether simulated swap output meets the 97% anti-honeypot / anti-transfer-tax threshold.
 */
export function evaluateSwapSimulation(
  tokenIn: string,
  tokenOut: string,
  symbolIn: string,
  symbolOut: string,
  amountInUsdc: number,
  quotedOut: number,
  simulatedOut: number,
  priceImpactPct: number
): SwapSimulationPreview {
  const effectiveRatioPct = quotedOut > 0 ? (simulatedOut / quotedOut) * 100 : 0;
  const isHoneypotOrTaxFlagged = effectiveRatioPct < 97.0;

  return {
    tokenIn,
    tokenOut,
    symbolIn,
    symbolOut,
    amountInUsdc,
    quotedOut,
    simulatedOut,
    effectiveRatioPct: Number(effectiveRatioPct.toFixed(2)),
    priceImpactPct: Number(priceImpactPct.toFixed(2)),
    isHoneypotOrTaxFlagged,
    statusMessageTr: isHoneypotOrTaxFlagged
      ? `ENGELLENDİ: Simülasyon çıktısı beklenenin %${effectiveRatioPct.toFixed(1)}'i (<%97). Transfer vergisi veya honeypot şüphesi nedeniyle token işaretlendi.`
      : `Simülasyon başarılı (%${effectiveRatioPct.toFixed(2)} net verim, fiyat etkisi %${priceImpactPct.toFixed(2)}).`,
  };
}
