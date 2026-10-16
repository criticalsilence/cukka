// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CukkaVault} from "../src/CukkaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory name_, string memory symbol_, uint8 dec_) ERC20(name_, symbol_) {
        _dec = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TestMorphoVault is ERC4626 {
    constructor(IERC20 asset_) ERC4626(asset_) ERC20("Morpho USDC Vault", "mUSDC") {}
}

contract TestAggregatorRouter {
    bool public shouldRevert;

    function setShouldRevert(bool _revert) external {
        shouldRevert = _revert;
    }

    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    ) external {
        require(!shouldRevert, "Router revert");
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        TestERC20(tokenOut).mint(recipient, amountOut);
    }
}

contract CukkaVaultTest is Test {
    CukkaVault public vault;
    TestERC20 public usdc;
    TestERC20 public weth;
    TestERC20 public meme;
    TestMorphoVault public morpho;
    TestAggregatorRouter public aggregator;

    address public admin = makeAddr("admin");
    address public manager = makeAddr("manager");
    address public oracle = makeAddr("oracle");
    address public feeRecipient = makeAddr("feeRecipient");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public attacker = makeAddr("attacker");

    function setUp() public {
        usdc = new TestERC20("USD Coin", "USDC", 6);
        weth = new TestERC20("Wrapped Ether", "WETH", 18);
        meme = new TestERC20("Base Meme", "MEME", 18);
        morpho = new TestMorphoVault(usdc);
        aggregator = new TestAggregatorRouter();

        vault = new CukkaVault(
            address(usdc),
            address(morpho),
            address(aggregator),
            admin,
            manager,
            oracle,
            feeRecipient
        );

        // Fund test users with USDC
        usdc.mint(alice, 1_000_000e6);
        usdc.mint(bob, 1_000_000e6);
        usdc.mint(attacker, 1_000_000e6);

        vm.prank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        usdc.approve(address(vault), type(uint256).max);

        vm.prank(attacker);
        usdc.approve(address(vault), type(uint256).max);
    }

    // =========================================================================
    // 1. Full Deposit & Withdraw Lifecycle + Soulbound Check
    // =========================================================================

    function test_DepositAndWithdrawFullCycle() public {
        // Alice deposits 1,000 USDC
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6);

        // Dead shares (1000 wei) minted to 0x...dEaD
        assertEq(vault.balanceOf(vault.DEAD_ADDRESS()), 1_000);
        assertEq(shares, 1_000e18 - 1_000);
        assertEq(vault.totalAssetsUsdc(), 1_000e6);
        assertEq(vault.currentNAVPerShare(), 1e18);

        // Soulbound check: Alice cannot transfer shares to Bob
        vm.prank(alice);
        vm.expectRevert(CukkaVault.SoulboundTokenNonTransferable.selector);
        vault.transfer(bob, 100e18);

        // Alice requests withdrawal of all her shares at 1.00 NAV (0 profit -> 0 fee)
        vm.prank(alice);
        uint256 reqId = vault.requestWithdraw(shares);

        (
            uint256 id,
            address reqUser,
            uint256 reqShares,
            uint256 feeShares,
            uint256 lockedNav,
            uint256 grossUsdc,
            uint256 netUsdc,
            ,
            CukkaVault.WithdrawStatus status
        ) = vault.withdrawRequests(reqId);

        assertEq(id, 1);
        assertEq(reqUser, alice);
        assertEq(reqShares, shares);
        assertEq(feeShares, 0);
        assertEq(lockedNav, 1e18);
        assertEq(grossUsdc, netUsdc);
        assertEq(uint8(status), uint8(CukkaVault.WithdrawStatus.Pending));

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        vm.prank(admin);
        vault.processWithdraw(reqId);

        assertEq(usdc.balanceOf(alice) - aliceUsdcBefore, netUsdc);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_CancelWithdrawRestoresShares() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(500e6);

        vm.prank(alice);
        uint256 reqId = vault.requestWithdraw(shares);
        assertEq(vault.balanceOf(alice), 0);

        // Bob cannot cancel Alice's request
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.NotRequestOwner.selector, bob, alice));
        vault.cancelWithdraw(reqId);

        // Alice cancels her request
        vm.prank(alice);
        vault.cancelWithdraw(reqId);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalPendingWithdrawUsdc(), 0);
    }

    // =========================================================================
    // 2. Multi-User Different Entry NAVs, HWM Accuracy & Option A Partial Exit
    // =========================================================================

    function test_MultiUserDifferentEntryNAVsAndHWM() public {
        // 1. Alice deposits 1,000 USDC at NAV = 1.00 ($1e18)
        vm.prank(alice);
        uint256 aliceShares1 = vault.deposit(1_000e6);
        (, uint256 aliceHwm1,) = vault.userPositions(alice);
        assertEq(aliceHwm1, 1e18);

        // 2. Portfolio grows +20% -> Oracle updates NAV to 1,200 USDC
        vm.prank(oracle);
        vault.updateNAV(1_200e6, keccak256("report-1"));
        assertEq(vault.currentNAVPerShare(), 1.2e18);

        // 3. Bob deposits 1,200 USDC at NAV = 1.20 ($1.2e18) -> gets 1,000e18 shares
        vm.prank(bob);
        uint256 bobShares = vault.deposit(1_200e6);
        assertEq(bobShares, 1_000e18);
        (, uint256 bobHwm,) = vault.userPositions(bob);
        assertEq(bobHwm, 1.2e18);

        // 4. Alice deposits another 1,200 USDC at NAV = 1.20 -> weighted HWM becomes ~1.10 ($1.1e18)
        vm.prank(alice);
        uint256 aliceShares2 = vault.deposit(1_200e6);
        (, uint256 aliceHwm2,) = vault.userPositions(alice);
        assertApproxEqAbs(aliceHwm2, 1.1e18, 1e12);

        // 5. Alice withdraws 50% of her shares (Option A: partial withdraw keeps remaining HWM at 1.10)
        uint256 totalAliceShares = aliceShares1 + aliceShares2;
        uint256 halfAliceShares = totalAliceShares / 2;

        vm.prank(alice);
        uint256 reqAlice = vault.requestWithdraw(halfAliceShares);

        // Fund vault with extra USDC representing realized profit so withdrawal can be paid
        usdc.mint(address(vault), 500e6);

        vm.prank(admin);
        vault.processWithdraw(reqAlice);

        // Fee recipient received performance fee in shares!
        uint256 feeRecipientShares = vault.balanceOf(feeRecipient);
        assertGt(feeRecipientShares, 0);

        // Alice's remaining shares STILL have HWM = 1.10 (Option A verified)
        (, uint256 aliceHwmAfterPartial,) = vault.userPositions(alice);
        assertEq(aliceHwmAfterPartial, aliceHwm2);

        // Bob withdraws at 1.20 NAV -> his HWM is 1.20, so Bob pays ZERO performance fee!
        vm.prank(bob);
        uint256 reqBob = vault.requestWithdraw(bobShares);
        (,,, uint256 bobFeeShares,,,,,) = vault.withdrawRequests(reqBob);
        assertEq(bobFeeShares, 0);
    }

    // =========================================================================
    // 3. Zero Performance Fee When In Loss
    // =========================================================================

    function test_ZeroFeeWhenInLoss() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6);

        // NAV drops -15% to 850 USDC
        vm.prank(oracle);
        vault.updateNAV(850e6, keccak256("loss-report"));

        vm.prank(alice);
        uint256 reqId = vault.requestWithdraw(shares);

        (,,, uint256 feeShares, uint256 lockedNav,, uint256 netUsdc,,) = vault.withdrawRequests(reqId);
        assertEq(feeShares, 0);
        assertEq(lockedNav, 0.85e18);
        assertApproxEqAbs(netUsdc, 850e6, 2);

        vm.prank(admin);
        vault.processWithdraw(reqId);
        assertEq(vault.balanceOf(feeRecipient), 0);
    }

    // =========================================================================
    // 4. Vault Inflation Attack Protection
    // =========================================================================

    function test_InflationAttackMitigated() public {
        // Attacker tries to deposit 1 wei -> reverts due to minInitialDeposit (0.10 USDC = 100_000)
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.InitialDepositBelowMinimum.selector, 1, 100_000));
        vault.deposit(1);

        // Attacker deposits minimum 10 USDC
        vm.prank(attacker);
        vault.deposit(10e6);

        // Attacker donates 100,000 USDC directly to the vault trying to inflate share price
        vm.prank(attacker);
        usdc.transfer(address(vault), 100_000e6);

        // Because NAV is oracle-controlled (`totalAssetsUsdc`), direct token donations do NOT inflate share price!
        assertEq(vault.currentNAVPerShare(), 1e18);

        // Alice deposits 100 USDC and receives her full fair 100e18 shares
        vm.prank(alice);
        uint256 aliceShares = vault.deposit(100e6);
        assertEq(aliceShares, 100e18);
    }

    // =========================================================================
    // 5. Swap Guardrails: Whitelist Timelock, Slippage, Position Cap, Cash Buffer, Daily Volume
    // =========================================================================

    function test_SwapGuardrailsAndTimelock() public {
        vm.prank(alice);
        vault.deposit(10_000e6); // 10,000 USDC NAV

        // 1. Swapping into non-whitelisted WETH reverts
        bytes memory dummyCall = abi.encodeWithSelector(
            TestAggregatorRouter.executeSwap.selector,
            address(usdc),
            address(weth),
            500e6,
            0.25e18,
            address(vault)
        );
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.TokenNotWhitelisted.selector, address(weth)));
        vault.swap(address(usdc), address(weth), 500e6, 0.245e18, dummyCall);

        // 2. Admin queues WETH with 10% max allocation (1000 bps) at $2,000 price (2000e6)
        vm.prank(admin);
        vault.queueTokenWhitelist(address(weth), 1_000, 2_000e6);

        // Activating before 24h timelock reverts
        vm.prank(admin);
        vm.expectRevert();
        vault.activateTokenWhitelist(address(weth));

        // Warp 24 hours + 1 second and refresh NAV timestamp
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(oracle);
        vault.updateNAV(10_000e6, keccak256("fresh-nav"));

        vm.prank(admin);
        vault.activateTokenWhitelist(address(weth));

        // 3. Slippage violation check (>3% slippage on minOut)
        // 500 USDC at $2,000/WETH = 0.25 WETH expected. Min allowed with 3% slippage = 0.2425 WETH.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.SlippageExceeded.selector, 0.23e18, 0.2425e18));
        vault.swap(address(usdc), address(weth), 500e6, 0.23e18, dummyCall);

        // 4. Valid swap of 500 USDC -> 0.25 WETH (5% of NAV <= 10% cap) succeeds
        vm.prank(manager);
        uint256 out = vault.swap(address(usdc), address(weth), 500e6, 0.245e18, dummyCall);
        assertEq(out, 0.25e18);

        // 5. Position limit violation check: swapping another 600 USDC -> 0.30 WETH puts WETH at $1,100 (> $1,000 10% cap)
        bytes memory overCapCall = abi.encodeWithSelector(
            TestAggregatorRouter.executeSwap.selector,
            address(usdc),
            address(weth),
            600e6,
            0.30e18,
            address(vault)
        );
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(CukkaVault.PositionLimitExceeded.selector, address(weth), 1_100e6, 1_000e6)
        );
        vault.swap(address(usdc), address(weth), 600e6, 0.295e18, overCapCall);

        // 6. Instant token removal from whitelist works without timelock
        vm.prank(admin);
        vault.removeTokenFromWhitelist(address(weth));
        (bool isWl,,,,,) = vault.tokenConfigs(address(weth));
        assertFalse(isWl);
    }

    function test_CashBufferAndDailyVolumeGuardrails() public {
        vm.prank(alice);
        vault.deposit(10_000e6);

        // Queue and activate WETH with 95% max allocation to test daily volume & cash buffer limits
        vm.prank(admin);
        vault.queueTokenWhitelist(address(weth), 9_500, 2_000e6);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(oracle);
        vault.updateNAV(10_000e6, keccak256("nav"));
        vm.prank(admin);
        vault.activateTokenWhitelist(address(weth));

        // Daily swap volume cap is 50% of NAV (5,000 USDC). Trying to swap 6,000 USDC reverts.
        bytes memory bigCall = abi.encodeWithSelector(
            TestAggregatorRouter.executeSwap.selector,
            address(usdc),
            address(weth),
            6_000e6,
            3e18,
            address(vault)
        );
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.DailySwapVolumeExceeded.selector, 6_000e6, 5_000e6));
        vault.swap(address(usdc), address(weth), 6_000e6, 2.95e18, bigCall);

        // Raise daily swap volume cap to 95% to test minimum cash buffer (10% = 1,000 USDC)
        vm.prank(admin);
        vault.setRiskParameters(300, 1_000, 1_000, 2_000, 9_500);

        // Trying to swap 9,200 USDC leaves only 800 USDC (< 1,000 USDC min cash buffer) -> reverts
        bytes memory drainBufferCall = abi.encodeWithSelector(
            TestAggregatorRouter.executeSwap.selector,
            address(usdc),
            address(weth),
            9_200e6,
            4.6e18,
            address(vault)
        );
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.CashBufferBelowMinimum.selector, 800e6, 1_000e6));
        vault.swap(address(usdc), address(weth), 9_200e6, 4.5e18, drainBufferCall);
    }

    // =========================================================================
    // 6. NAV Delta Circuit Breaker & Emergency Approval
    // =========================================================================

    function test_NavDeltaCircuitBreaker() public {
        vm.prank(alice);
        vault.deposit(1_000e6);

        // Oracle tries to update NAV by +25% (> 20% maxNavDeltaBps) -> reverts
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(CukkaVault.NavDeltaExceeded.selector, 1_000e6, 1_250e6, 2_000));
        vault.updateNAV(1_250e6, keccak256("spike"));

        // Admin approves emergency NAV update
        vm.prank(admin);
        vault.approveEmergencyNAV(1_250e6, keccak256("spike-approved"));
        assertEq(vault.totalAssetsUsdc(), 1_250e6);
    }

    // =========================================================================
    // 7. Pause Behavior (Deposits & Swaps Stop; Withdrawals Still Work!)
    // =========================================================================

    function test_PauseBlocksDepositsButAllowsWithdrawals() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6);

        vm.prank(admin);
        vault.pause();

        // Deposit reverts while paused
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(500e6);

        // Alice can STILL requestWithdraw and Admin can processWithdraw while paused!
        vm.prank(alice);
        uint256 reqId = vault.requestWithdraw(shares);

        vm.prank(admin);
        vault.processWithdraw(reqId);
        assertEq(vault.balanceOf(alice), 0);

        vm.prank(admin);
        vault.unpause();

        vm.prank(bob);
        vault.deposit(500e6);
        assertGt(vault.balanceOf(bob), 0);
    }

    // =========================================================================
    // 8. Unauthorized Access & Morpho Yield Integration + Fee Timelock
    // =========================================================================

    function test_UnauthorizedCallsAndMorphoYieldIntegration() public {
        vm.prank(alice);
        vault.deposit(2_000e6);

        // Attacker cannot call manager, oracle, or admin functions
        vm.startPrank(attacker);
        vm.expectRevert();
        vault.depositToYield(500e6);
        vm.expectRevert();
        vault.updateNAV(2_100e6, bytes32(0));
        vm.expectRevert();
        vault.pause();
        vm.stopPrank();

        // Manager deposits 1,500 USDC into Base Earn (Morpho) vault
        vm.prank(manager);
        uint256 morphoShares = vault.depositToYield(1_500e6);
        assertGt(morphoShares, 0);
        assertEq(vault.yieldBalanceUsdc(), 1_500e6);
        assertEq(vault.totalCashBufferUsdc(), 2_000e6);

        // Manager withdraws 500 USDC from Morpho vault
        vm.prank(manager);
        vault.withdrawFromYield(500e6);
        assertEq(vault.yieldBalanceUsdc(), 1_000e6);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);

        // Performance fee reduction is immediate; increase is timelocked
        vm.prank(admin);
        vault.setPerformanceFeeBps(1_000); // 15% -> 10% instant
        assertEq(vault.performanceFeeBps(), 1_000);

        vm.prank(admin);
        vault.setPerformanceFeeBps(2_000); // 10% -> 20% queued
        assertEq(vault.performanceFeeBps(), 1_000); // Still 10%

        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(admin);
        vault.activatePerformanceFeeIncrease();
        assertEq(vault.performanceFeeBps(), 2_000);
    }

    function test_AdminConfigsAndEdgeCases() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6);

        // Update token prices
        address[] memory tokens = new address[](1);
        tokens[0] = address(usdc);
        uint256[] memory prices = new uint256[](1);
        prices[0] = 1e6;
        vm.prank(oracle);
        vault.updateTokenPrices(tokens, prices);

        // Admin setters
        vm.startPrank(admin);
        vault.setAggregator(address(0x1234));
        vault.setYieldVault(address(morpho));
        vault.setFeeRecipient(address(0x5678));
        vault.setWhitelistTimelock(12 hours);
        vm.stopPrank();

        assertEq(vault.getWhitelistedTokens().length, 1);

        // Insufficient idle cash on processWithdraw reverts until Morpho is withdrawn
        vm.prank(manager);
        vault.depositToYield(900e6); // Only 100 USDC idle left

        vm.prank(alice);
        uint256 reqId = vault.requestWithdraw(shares);
        assertEq(vault.getUserWithdrawRequests(alice).length, 1);

        vm.prank(admin);
        vm.expectRevert();
        vault.processWithdraw(reqId);

        // Manager pulls cash back from Morpho, then Admin processes withdrawal
        vm.prank(manager);
        vault.withdrawFromYield(900e6);

        vm.prank(admin);
        vault.processWithdraw(reqId);
    }

    function test_AllErrorBranchesAndStaleNav() public {
        // Constructor zero address revert
        vm.expectRevert(CukkaVault.ZeroAddress.selector);
        new CukkaVault(address(0), address(morpho), address(aggregator), admin, manager, oracle, feeRecipient);

        // Zero amount deposit revert
        vm.prank(alice);
        vm.expectRevert(CukkaVault.ZeroAmount.selector);
        vault.deposit(0);

        // Deposit 1,000 USDC
        vm.prank(alice);
        uint256 shares = vault.deposit(1_000e6);

        // InsufficientShares & ZeroAmount on requestWithdraw
        vm.startPrank(alice);
        vm.expectRevert(CukkaVault.ZeroAmount.selector);
        vault.requestWithdraw(0);

        vm.expectRevert(abi.encodeWithSelector(CukkaVault.InsufficientShares.selector, shares + 1, shares));
        vault.requestWithdraw(shares + 1);
        vm.stopPrank();

        // Stale NAV revert after 24h + 1s without oracle update
        vm.warp(block.timestamp + 25 hours);
        vm.prank(bob);
        vm.expectRevert();
        vault.deposit(100e6);

        // Refresh NAV
        vm.prank(oracle);
        vault.updateNAV(1_000e6, keccak256("refreshed"));

        // Admin error branches
        vm.startPrank(admin);
        vm.expectRevert(CukkaVault.CannotRemoveBaseAsset.selector);
        vault.removeTokenFromWhitelist(address(usdc));

        vm.expectRevert(CukkaVault.TimelockNotQueued.selector);
        vault.activateTokenWhitelist(address(meme));

        vm.expectRevert(CukkaVault.TimelockNotQueued.selector);
        vault.activatePerformanceFeeIncrease();

        vm.expectRevert(abi.encodeWithSelector(CukkaVault.InvalidBpsValue.selector, 4_000));
        vault.setPerformanceFeeBps(4_000);

        vm.expectRevert(CukkaVault.ZeroAddress.selector);
        vault.setAggregator(address(0));

        vm.expectRevert(CukkaVault.ZeroAddress.selector);
        vault.setYieldVault(address(0));

        vm.expectRevert(CukkaVault.ZeroAddress.selector);
        vault.setFeeRecipient(address(0));

        vm.expectRevert(abi.encodeWithSelector(CukkaVault.InvalidBpsValue.selector, 10));
        vault.setWhitelistTimelock(10);
        vm.stopPrank();

        // Aggregator failure branch
        vm.prank(admin);
        vault.queueTokenWhitelist(address(weth), 1_000, 2_000e6);
        vm.warp(block.timestamp + 24 hours + 1);
        vm.prank(oracle);
        vault.updateNAV(1_000e6, keccak256("refreshed-2"));
        vm.prank(admin);
        vault.activateTokenWhitelist(address(weth));

        aggregator.setShouldRevert(true);
        bytes memory callData = abi.encodeWithSelector(
            TestAggregatorRouter.executeSwap.selector,
            address(usdc),
            address(weth),
            50e6,
            0.025e18,
            address(vault)
        );
        vm.prank(manager);
        vm.expectRevert(CukkaVault.AggregatorCallFailed.selector);
        vault.swap(address(usdc), address(weth), 50e6, 0.0245e18, callData);
    }

    // =========================================================================
    // 9. Fuzz Test: Rounding Loss Is Always in Favor of the Vault
    // =========================================================================

    function testFuzz_RoundingAlwaysFavorsVault(uint256 initDeposit, uint256 navMultiplierBps, uint256 secondDeposit)
        public
    {
        initDeposit = bound(initDeposit, 10e6, 100_000e6);
        navMultiplierBps = bound(navMultiplierBps, 8_500, 11_900); // -15% to +19%
        secondDeposit = bound(secondDeposit, 1e6, 100_000e6);

        vm.prank(alice);
        vault.deposit(initDeposit);

        uint256 updatedNav = (initDeposit * navMultiplierBps) / 10_000;
        if (updatedNav == 0) updatedNav = 1e6;

        vm.prank(oracle);
        vault.updateNAV(updatedNav, keccak256("fuzz-nav"));

        // Ensure vault has enough USDC to cover positive NAV for withdrawal test
        if (updatedNav > initDeposit) {
            usdc.mint(address(vault), updatedNav - initDeposit);
        }

        uint256 navBeforeSecond = vault.totalAssetsUsdc();
        uint256 supplyBeforeSecond = vault.totalSupply();

        vm.prank(bob);
        uint256 bobShares = vault.deposit(secondDeposit);

        // Verify Bob's shares converted back to USDC never exceed his deposit (rounding favors vault)
        uint256 bobImmediateUsdcValue = vault.convertToUsdc(bobShares);
        assertLe(bobImmediateUsdcValue, secondDeposit);

        // Verify invariant: bobShares * navBeforeSecond <= secondDeposit * supplyBeforeSecond
        assertLe(bobShares * navBeforeSecond, secondDeposit * supplyBeforeSecond);
    }
}
