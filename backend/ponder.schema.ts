import { createSchema } from "@ponder/core";

export default createSchema((p) => ({
  UserAccount: p.createTable({
    id: p.hex(), // Smart account address
    inviteCode: p.string().optional(),
    costBasisUsdc: p.bigint(),
    sharesBalance: p.bigint(),
    lockedShares: p.bigint(),
    highWaterMark: p.bigint(),
    walletUsdcBalance: p.bigint(),
    updatedAt: p.bigint(),
  }),

  VaultNavSnapshot: p.createTable({
    id: p.string(), // txHash-logIndex
    totalAssetsUsdc: p.bigint(),
    navPerShare: p.bigint(),
    reportHash: p.hex(),
    isEmergencyApproved: p.boolean(),
    timestamp: p.bigint(),
    blockNumber: p.bigint(),
  }),

  WithdrawQueueItem: p.createTable({
    id: p.bigint(), // requestId
    user: p.hex(),
    shares: p.bigint(),
    feeShares: p.bigint(),
    lockedNavPerShare: p.bigint(),
    grossUsdc: p.bigint(),
    netUsdc: p.bigint(),
    status: p.string(), // PENDING | PROCESSED | CANCELLED
    requestedAt: p.bigint(),
    processedAt: p.bigint().optional(),
    txHash: p.hex(),
  }),

  VaultSwapLog: p.createTable({
    id: p.string(),
    tokenIn: p.hex(),
    tokenOut: p.hex(),
    amountIn: p.bigint(),
    amountOut: p.bigint(),
    usdcValueIn: p.bigint(),
    rationaleNote: p.string().optional(),
    timestamp: p.bigint(),
    txHash: p.hex(),
  }),
}));
