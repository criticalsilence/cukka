import { ponder } from "@/generated";

/**
 * Ponder Event Indexer — CUKKA V1
 * Indexes Deposit, WithdrawRequested, WithdrawProcessed, WithdrawCancelled,
 * Swapped, NAVUpdated, and incoming USDC transfers to user smart accounts.
 */

ponder.on("CukkaVault:Deposited", async ({ event, context }) => {
  const { UserAccount } = context.db;
  const userAddr = event.args.user.toLowerCase() as `0x${string}`;

  await UserAccount.upsert({
    id: userAddr,
    create: {
      costBasisUsdc: event.args.usdcAmount,
      sharesBalance: event.args.sharesMinted,
      lockedShares: 0n,
      highWaterMark: event.args.newHighWaterMark,
      walletUsdcBalance: 0n,
      updatedAt: event.block.timestamp,
    },
    update: ({ current }) => ({
      costBasisUsdc: current.costBasisUsdc + event.args.usdcAmount,
      sharesBalance: current.sharesBalance + event.args.sharesMinted,
      highWaterMark: event.args.newHighWaterMark,
      updatedAt: event.block.timestamp,
    }),
  });
});

ponder.on("CukkaVault:WithdrawRequested", async ({ event, context }) => {
  const { WithdrawQueueItem, UserAccount } = context.db;
  const userAddr = event.args.user.toLowerCase() as `0x${string}`;

  await WithdrawQueueItem.create({
    id: event.args.requestId,
    data: {
      user: userAddr,
      shares: event.args.shares,
      feeShares: event.args.feeShares,
      lockedNavPerShare: event.args.lockedNavPerShare,
      grossUsdc: event.args.grossUsdc,
      netUsdc: event.args.netUsdc,
      status: "PENDING",
      requestedAt: event.block.timestamp,
      txHash: event.transaction.hash,
    },
  });

  await UserAccount.update({
    id: userAddr,
    data: ({ current }) => ({
      sharesBalance: current.sharesBalance - event.args.shares,
      lockedShares: current.lockedShares + event.args.shares,
      updatedAt: event.block.timestamp,
    }),
  });
});

ponder.on("CukkaVault:WithdrawProcessed", async ({ event, context }) => {
  const { WithdrawQueueItem, UserAccount } = context.db;
  const userAddr = event.args.user.toLowerCase() as `0x${string}`;

  await WithdrawQueueItem.update({
    id: event.args.requestId,
    data: {
      status: "PROCESSED",
      processedAt: event.block.timestamp,
    },
  });

  const totalBurnedAndFee = event.args.sharesBurned + event.args.feeSharesMinted;
  await UserAccount.update({
    id: userAddr,
    data: ({ current }) => ({
      lockedShares: current.lockedShares > totalBurnedAndFee ? current.lockedShares - totalBurnedAndFee : 0n,
      updatedAt: event.block.timestamp,
    }),
  });
});

ponder.on("CukkaVault:WithdrawCancelled", async ({ event, context }) => {
  const { WithdrawQueueItem, UserAccount } = context.db;
  const userAddr = event.args.user.toLowerCase() as `0x${string}`;

  await WithdrawQueueItem.update({
    id: event.args.requestId,
    data: {
      status: "CANCELLED",
    },
  });

  await UserAccount.update({
    id: userAddr,
    data: ({ current }) => ({
      sharesBalance: current.sharesBalance + event.args.sharesReturned,
      lockedShares: current.lockedShares - event.args.sharesReturned,
      updatedAt: event.block.timestamp,
    }),
  });
});

ponder.on("CukkaVault:NAVUpdated", async ({ event, context }) => {
  const { VaultNavSnapshot } = context.db;
  await VaultNavSnapshot.create({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    data: {
      totalAssetsUsdc: event.args.newTotalAssetsUsdc,
      navPerShare: event.args.navPerShare,
      reportHash: event.args.reportHash,
      isEmergencyApproved: event.args.isEmergencyApproved,
      timestamp: event.block.timestamp,
      blockNumber: event.block.number,
    },
  });
});

ponder.on("CukkaVault:Swapped", async ({ event, context }) => {
  const { VaultSwapLog } = context.db;
  await VaultSwapLog.create({
    id: `${event.transaction.hash}-${event.log.logIndex}`,
    data: {
      tokenIn: event.args.tokenIn,
      tokenOut: event.args.tokenOut,
      amountIn: event.args.amountIn,
      amountOut: event.args.amountOut,
      usdcValueIn: event.args.usdcValueIn,
      timestamp: event.block.timestamp,
      txHash: event.transaction.hash,
    },
  });
});
