// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC4626Yield} from "./interfaces/IERC4626Yield.sol";

/**
 * @title CukkaVault
 * @notice Non-custodial pooled crypto portfolio vault on Base.
 * @dev Shares (cukkaSHARE) are soulbound (non-transferable between users) and can only be minted/burned
 *      against the vault or escrowed during withdrawal requests.
 *      Admin and Manager roles CANNOT withdraw user funds; the only exit path for funds is a user's
 *      own withdrawal request (`requestWithdraw` -> `processWithdraw`).
 */
contract CukkaVault is ERC20, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // =========================================================================
    // Roles & Constants
    // =========================================================================

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant NAV_PRECISION = 1e18; // 1.00 USDC per 1e18 share = 1e18
    uint256 public constant SHARE_OFFSET = 1e12;  // Converts 6-decimal USDC to 18-decimal shares
    uint256 public constant DEAD_SHARES = 1_000;  // Burned to 0x...dEaD on initial deposit (inflation guard)
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3_000; // Hard cap: 30%
    uint16 public constant MAX_SLIPPAGE_CAP_BPS = 1_000;    // Hard cap: 10%

    // =========================================================================
    // Data Structures
    // =========================================================================

    struct UserPosition {
        uint256 costBasisUsdc;  // Net USDC principal deposited (6 decimals)
        uint256 highWaterMark;  // HWM NAV per share in 1e18 precision
        uint256 lockedShares;   // Shares currently locked in pending withdrawal requests
    }

    enum WithdrawStatus {
        None,
        Pending,
        Processed,
        Cancelled
    }

    struct WithdrawRequest {
        uint256 id;
        address user;
        uint256 shares;            // Total shares locked by user
        uint256 feeShares;         // Performance fee shares crystallized at request time
        uint256 lockedNavPerShare; // NAV per share (1e18) locked at request time
        uint256 grossUsdc;         // Gross USDC value before performance fee
        uint256 netUsdc;           // Exact net USDC to be paid to user
        uint64 requestedAt;
        WithdrawStatus status;
    }

    struct TokenConfig {
        bool isWhitelisted;
        uint8 tokenDecimals;
        uint16 maxAllocationBps;   // Max % of NAV allowed in this token (e.g., 1000 = 10%)
        uint64 queuedAt;           // Timestamp when queued for timelock
        uint16 pendingMaxAllocBps; // Pending max allocation during timelock
        uint256 lastPriceUsdc;     // Last oracle-verified price per 1 whole token in USDC (6 decimals)
    }

    // =========================================================================
    // State Variables
    // =========================================================================

    IERC20 public immutable usdc;
    IERC4626Yield public yieldVault; // Base Earn (Morpho USDC ERC-4626 vault)
    address public defaultAggregator;
    address public feeRecipient;

    // NAV Accounting
    uint256 public totalAssetsUsdc;   // Current realistic NAV in USDC (6 decimals)
    bytes32 public latestReportHash;  // Keccak-256 hash of offchain JSON valuation report
    uint64 public lastNavUpdateTime;
    uint64 public maxNavAge = 24 hours;

    // Guardrail Parameters
    uint16 public performanceFeeBps = 1_500;       // Default 15%
    uint16 public maxSlippageBps = 300;            // Default 3%
    uint16 public minCashBufferBps = 1_000;        // Default 10%
    uint16 public defaultMaxPositionBps = 1_000;   // Default 10%
    uint16 public maxNavDeltaBps = 2_000;          // Default 20%
    uint16 public maxDailySwapVolumeBps = 5_000;   // Default 50% of NAV per 24h
    uint64 public whitelistTimelock = 24 hours;    // Default 24h timelock
    uint256 public minInitialDeposit = 100_000;    // Default 0.10 USDC (1e5 = 1e17 share wei >> 1000 dead shares)

    // Pending Performance Fee Increase (Timelocked)
    uint16 public pendingPerformanceFeeBps;
    uint64 public pendingFeeIncreaseExecutableAt;

    // 24h Rolling Swap Volume Tracking
    uint64 public currentSwapDayWindowStart;
    uint256 public dailySwapVolumeUsdc;

    // Pending Withdrawal Liability Tracking
    uint256 public totalPendingWithdrawUsdc;
    uint256 public nextWithdrawRequestId = 1;

    // Mappings
    mapping(address => UserPosition) public userPositions;
    mapping(uint256 => WithdrawRequest) public withdrawRequests;
    mapping(address => uint256[]) private _userWithdrawIds;
    mapping(address => TokenConfig) public tokenConfigs;
    address[] private _whitelistedTokens;

    // =========================================================================
    // Events
    // =========================================================================

    event Deposited(
        address indexed user,
        uint256 usdcAmount,
        uint256 sharesMinted,
        uint256 navPerShare,
        uint256 newHighWaterMark
    );
    event WithdrawRequested(
        uint256 indexed requestId,
        address indexed user,
        uint256 shares,
        uint256 feeShares,
        uint256 lockedNavPerShare,
        uint256 grossUsdc,
        uint256 netUsdc
    );
    event WithdrawProcessed(
        uint256 indexed requestId,
        address indexed user,
        uint256 sharesBurned,
        uint256 feeSharesMinted,
        uint256 netUsdcPaid
    );
    event WithdrawCancelled(uint256 indexed requestId, address indexed user, uint256 sharesReturned);
    event NAVUpdated(
        uint256 oldTotalAssetsUsdc,
        uint256 newTotalAssetsUsdc,
        uint256 navPerShare,
        bytes32 indexed reportHash,
        bool isEmergencyApproved
    );
    event TokenPriceUpdated(address indexed token, uint256 priceUsdc);
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 usdcValueIn
    );
    event YieldDeposited(uint256 usdcAmount, uint256 morphoSharesReceived);
    event YieldWithdrawn(uint256 usdcAmount, uint256 morphoSharesBurned);
    event TokenWhitelistQueued(address indexed token, uint16 maxAllocationBps, uint64 executableAt);
    event TokenWhitelistActivated(address indexed token, uint16 maxAllocationBps);
    event TokenWhitelistRemoved(address indexed token);
    event PerformanceFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event PerformanceFeeIncreaseQueued(uint16 newFeeBps, uint64 executableAt);
    event ParametersUpdated(
        uint16 maxSlippageBps,
        uint16 minCashBufferBps,
        uint16 defaultMaxPositionBps,
        uint16 maxNavDeltaBps,
        uint16 maxDailySwapVolumeBps
    );
    event AggregatorUpdated(address indexed oldAggregator, address indexed newAggregator);
    event YieldVaultUpdated(address indexed oldYieldVault, address indexed newYieldVault);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event WhitelistTimelockUpdated(uint64 oldTimelock, uint64 newTimelock);

    // =========================================================================
    // Custom Errors
    // =========================================================================

    error ZeroAddress();
    error ZeroAmount();
    error SoulboundTokenNonTransferable();
    error InitialDepositBelowMinimum(uint256 provided, uint256 minimum);
    error ZeroSharesMinted();
    error InsufficientShares(uint256 requested, uint256 available);
    error InvalidWithdrawRequest(uint256 requestId);
    error NotRequestOwner(address caller, address owner);
    error InsufficientCashForWithdrawal(uint256 availableUsdc, uint256 requiredUsdc);
    error NavStale(uint64 lastUpdated, uint64 maxAge);
    error NavDeltaExceeded(uint256 oldNav, uint256 newNav, uint16 maxDeltaBps);
    error TokenNotWhitelisted(address token);
    error TimelockNotExpired(uint64 currentTimestamp, uint64 executableAt);
    error TimelockNotQueued();
    error SlippageExceeded(uint256 actualOut, uint256 minOutRequired);
    error PositionLimitExceeded(address token, uint256 postSwapValueUsdc, uint256 maxAllowedUsdc);
    error CashBufferBelowMinimum(uint256 postSwapCashUsdc, uint256 minRequiredCashUsdc);
    error DailySwapVolumeExceeded(uint256 projectedDailyVolumeUsdc, uint256 maxDailyVolumeUsdc);
    error AggregatorCallFailed();
    error InvalidBpsValue(uint256 value);
    error CannotRemoveBaseAsset();

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(
        address _usdc,
        address _yieldVault,
        address _defaultAggregator,
        address _admin,
        address _manager,
        address _oracle,
        address _feeRecipient
    ) ERC20("Cukka Portfolio Share", "cukkaSHARE") {
        if (
            _usdc == address(0) ||
            _admin == address(0) ||
            _manager == address(0) ||
            _oracle == address(0) ||
            _feeRecipient == address(0)
        ) revert ZeroAddress();

        usdc = IERC20(_usdc);
        yieldVault = IERC4626Yield(_yieldVault);
        defaultAggregator = _defaultAggregator;
        feeRecipient = _feeRecipient;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(MANAGER_ROLE, _manager);
        _grantRole(ORACLE_ROLE, _oracle);
        _grantRole(ORACLE_ROLE, _admin);

        // Base asset (USDC) is whitelisted by default at 100% max allocation and 1.00 USDC price
        tokenConfigs[_usdc] = TokenConfig({
            isWhitelisted: true,
            tokenDecimals: 6,
            maxAllocationBps: 10_000,
            queuedAt: 0,
            pendingMaxAllocBps: 0,
            lastPriceUsdc: 1e6
        });
        _whitelistedTokens.push(_usdc);

        lastNavUpdateTime = uint64(block.timestamp);
        currentSwapDayWindowStart = uint64(block.timestamp);
    }

    // =========================================================================
    // Soulbound ERC-20 Enforcement
    // =========================================================================

    /**
     * @dev Overrides OpenZeppelin ERC20 `_update` so `cukkaSHARE` cannot be transferred between users.
     *      Permitted movements:
     *      1. Minting (`from == address(0)`)
     *      2. Burning (`to == address(0)`)
     *      3. Locking shares into vault escrow on `requestWithdraw` (`to == address(this)`)
     *      4. Returning shares on `cancelWithdraw` or transferring crystallized fee shares to
     *         `feeRecipient` on `processWithdraw` (`from == address(this)`)
     */
    function _update(address from, address to, uint256 value) internal override {
        if (
            from != address(0) &&
            to != address(0) &&
            from != address(this) &&
            to != address(this)
        ) {
            revert SoulboundTokenNonTransferable();
        }
        super._update(from, to, value);
    }

    // =========================================================================
    // View Helpers (NAV & Cash Buffer)
    // =========================================================================

    /**
     * @notice Current NAV per full share (1e18 shares), scaled to 1e18 (1.00 USDC = 1e18).
     */
    function currentNAVPerShare() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || totalAssetsUsdc == 0) {
            return NAV_PRECISION; // 1.00 USDC initial price per share
        }
        return totalAssetsUsdc.mulDiv(SHARE_OFFSET * NAV_PRECISION, supply, Math.Rounding.Floor);
    }

    /**
     * @notice Converts a USDC amount (6 decimals) to shares (18 decimals), rounding down in vault's favor.
     */
    function convertToShares(uint256 usdcAmount) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || totalAssetsUsdc == 0) {
            return usdcAmount * SHARE_OFFSET;
        }
        return usdcAmount.mulDiv(supply, totalAssetsUsdc, Math.Rounding.Floor);
    }

    /**
     * @notice Converts shares (18 decimals) to USDC (6 decimals), rounding down in vault's favor.
     */
    function convertToUsdc(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0 || totalAssetsUsdc == 0) {
            return shares / SHARE_OFFSET;
        }
        return shares.mulDiv(totalAssetsUsdc, supply, Math.Rounding.Floor);
    }

    /**
     * @notice Total USDC held in the Base Earn (Morpho) ERC-4626 cash buffer vault.
     */
    function yieldBalanceUsdc() public view returns (uint256) {
        if (address(yieldVault) == address(0)) return 0;
        uint256 yieldShares = yieldVault.balanceOf(address(this));
        if (yieldShares == 0) return 0;
        return yieldVault.convertToAssets(yieldShares);
    }

    /**
     * @notice Total liquid cash buffer (idle USDC + Morpho USDC), excluding pending withdrawal locks.
     */
    function totalCashBufferUsdc() public view returns (uint256) {
        uint256 grossCash = usdc.balanceOf(address(this)) + yieldBalanceUsdc();
        if (grossCash <= totalPendingWithdrawUsdc) return 0;
        return grossCash - totalPendingWithdrawUsdc;
    }

    /**
     * @notice Preview withdrawal numbers (lockedNavPerShare, feeShares, grossUsdc, netUsdc) for a user right now.
     */
    function previewWithdraw(address user, uint256 shares)
        public
        view
        returns (uint256 navPerShare, uint256 feeShares, uint256 grossUsdc, uint256 netUsdc)
    {
        navPerShare = currentNAVPerShare();
        grossUsdc = convertToUsdc(shares);

        uint256 userHwm = userPositions[user].highWaterMark;
        uint256 hwmUsdc = shares.mulDiv(userHwm, SHARE_OFFSET * NAV_PRECISION, Math.Rounding.Ceil);
        if (userHwm > 0 && navPerShare > userHwm && grossUsdc > hwmUsdc && performanceFeeBps > 0) {
            uint256 profitPerShare = navPerShare - userHwm;
            // feeInUsdcPerShare = profitPerShare * performanceFeeBps / 10000
            // feeShares = shares * feeInUsdcPerShare / navPerShare
            feeShares = shares.mulDiv(
                profitPerShare * performanceFeeBps,
                BPS_DENOMINATOR * navPerShare,
                Math.Rounding.Floor
            );
        }

        uint256 netShares = shares - feeShares;
        netUsdc = convertToUsdc(netShares);
    }

    function getWhitelistedTokens() external view returns (address[] memory) {
        return _whitelistedTokens;
    }

    function getUserWithdrawRequests(address user) external view returns (uint256[] memory) {
        return _userWithdrawIds[user];
    }

    // =========================================================================
    // User Actions: Deposit & Withdraw
    // =========================================================================

    /**
     * @notice Deposits USDC into the vault and mints soulbound `cukkaSHARE` at current NAV.
     * @param usdcAmount Amount of USDC (6 decimals) to deposit.
     */
    function deposit(uint256 usdcAmount) external whenNotPaused nonReentrant returns (uint256 sharesMinted) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireFreshNav();

        uint256 supplyBefore = totalSupply();
        uint256 navPerShare = currentNAVPerShare();

        if (supplyBefore == 0) {
            if (usdcAmount < minInitialDeposit) {
                revert InitialDepositBelowMinimum(usdcAmount, minInitialDeposit);
            }
            uint256 grossShares = usdcAmount * SHARE_OFFSET;
            _mint(DEAD_ADDRESS, DEAD_SHARES);
            sharesMinted = grossShares - DEAD_SHARES;
        } else {
            sharesMinted = convertToShares(usdcAmount);
        }

        if (sharesMinted == 0) revert ZeroSharesMinted();

        // Update user's weighted-average High-Water Mark before minting
        UserPosition storage pos = userPositions[msg.sender];
        uint256 existingUserShares = balanceOf(msg.sender) + pos.lockedShares;

        if (existingUserShares == 0 || pos.highWaterMark == 0) {
            pos.highWaterMark = navPerShare;
        } else {
            pos.highWaterMark = (
                (existingUserShares * pos.highWaterMark) + (sharesMinted * navPerShare)
            ) / (existingUserShares + sharesMinted);
        }

        pos.costBasisUsdc += usdcAmount;
        totalAssetsUsdc += usdcAmount;

        _mint(msg.sender, sharesMinted);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        emit Deposited(msg.sender, usdcAmount, sharesMinted, navPerShare, pos.highWaterMark);
    }

    /**
     * @notice Locks `shares` in the withdrawal queue at the current NAV per share.
     *         Works even when the contract is paused so users are never locked in.
     * @param shares Amount of `cukkaSHARE` (18 decimals) to redeem.
     */
    function requestWithdraw(uint256 shares) external nonReentrant returns (uint256 requestId) {
        if (shares == 0) revert ZeroAmount();
        uint256 available = balanceOf(msg.sender);
        if (shares > available) revert InsufficientShares(shares, available);

        (uint256 navPerShare, uint256 feeShares, uint256 grossUsdc, uint256 netUsdc) =
            previewWithdraw(msg.sender, shares);

        if (netUsdc == 0) revert ZeroAmount();

        // Move shares from user into vault escrow
        _update(msg.sender, address(this), shares);
        userPositions[msg.sender].lockedShares += shares;
        totalPendingWithdrawUsdc += netUsdc;

        requestId = nextWithdrawRequestId++;
        withdrawRequests[requestId] = WithdrawRequest({
            id: requestId,
            user: msg.sender,
            shares: shares,
            feeShares: feeShares,
            lockedNavPerShare: navPerShare,
            grossUsdc: grossUsdc,
            netUsdc: netUsdc,
            requestedAt: uint64(block.timestamp),
            status: WithdrawStatus.Pending
        });
        _userWithdrawIds[msg.sender].push(requestId);

        emit WithdrawRequested(requestId, msg.sender, shares, feeShares, navPerShare, grossUsdc, netUsdc);
    }

    /**
     * @notice Allows a user to cancel their own pending withdrawal request and unlock their shares.
     */
    function cancelWithdraw(uint256 requestId) external nonReentrant {
        WithdrawRequest storage req = withdrawRequests[requestId];
        if (req.status != WithdrawStatus.Pending) revert InvalidWithdrawRequest(requestId);
        if (req.user != msg.sender) revert NotRequestOwner(msg.sender, req.user);

        req.status = WithdrawStatus.Cancelled;
        userPositions[msg.sender].lockedShares -= req.shares;
        totalPendingWithdrawUsdc -= req.netUsdc;

        _update(address(this), msg.sender, req.shares);

        emit WithdrawCancelled(requestId, msg.sender, req.shares);
    }

    /**
     * @notice Processes a pending withdrawal request at its locked NAV, crystallizes performance fee
     *         in shares to `feeRecipient`, burns net shares, and transfers USDC to `req.user`.
     */
    function processWithdraw(uint256 requestId) external onlyRole(ADMIN_ROLE) nonReentrant {
        WithdrawRequest storage req = withdrawRequests[requestId];
        if (req.status != WithdrawStatus.Pending) revert InvalidWithdrawRequest(requestId);

        uint256 idleUsdc = usdc.balanceOf(address(this));
        if (idleUsdc < req.netUsdc) {
            revert InsufficientCashForWithdrawal(idleUsdc, req.netUsdc);
        }

        req.status = WithdrawStatus.Processed;
        UserPosition storage userPos = userPositions[req.user];

        // Proportionally reduce user's costBasisUsdc based on total shares before burn
        uint256 totalUserSharesBefore = balanceOf(req.user) + userPos.lockedShares;
        userPos.lockedShares -= req.shares;
        if (totalUserSharesBefore > 0) {
            uint256 costReduction = userPos.costBasisUsdc.mulDiv(req.shares, totalUserSharesBefore, Math.Rounding.Floor);
            userPos.costBasisUsdc = userPos.costBasisUsdc > costReduction
                ? userPos.costBasisUsdc - costReduction
                : 0;
        }

        // If user has exited 100% of their shares, reset their HWM; otherwise keep remaining shares' HWM (Option A)
        if (balanceOf(req.user) + userPos.lockedShares == 0) {
            userPos.highWaterMark = 0;
            userPos.costBasisUsdc = 0;
        }

        totalPendingWithdrawUsdc -= req.netUsdc;

        // Crystallize performance fee in shares to feeRecipient (does not touch vault liquidity)
        if (req.feeShares > 0) {
            UserPosition storage feePos = userPositions[feeRecipient];
            uint256 feeRecipientExisting = balanceOf(feeRecipient) + feePos.lockedShares;
            if (feeRecipientExisting == 0 || feePos.highWaterMark == 0) {
                feePos.highWaterMark = req.lockedNavPerShare;
            } else {
                feePos.highWaterMark = (
                    (feeRecipientExisting * feePos.highWaterMark) + (req.feeShares * req.lockedNavPerShare)
                ) / (feeRecipientExisting + req.feeShares);
            }
            _update(address(this), feeRecipient, req.feeShares);
        }

        // Burn remaining net shares from escrow
        uint256 netSharesToBurn = req.shares - req.feeShares;
        _burn(address(this), netSharesToBurn);

        // Deduct paid USDC from totalAssetsUsdc
        if (totalAssetsUsdc >= req.netUsdc) {
            totalAssetsUsdc -= req.netUsdc;
        } else {
            totalAssetsUsdc = 0;
        }

        usdc.safeTransfer(req.user, req.netUsdc);

        emit WithdrawProcessed(requestId, req.user, netSharesToBurn, req.feeShares, req.netUsdc);
    }

    // =========================================================================
    // Oracle Actions: NAV & Token Price Updates
    // =========================================================================

    /**
     * @notice Updates vault realistic NAV (in 6-decimal USDC) and stores offchain report hash.
     *         Enforces `±maxNavDeltaBps` circuit breaker against compromised oracle keys.
     */
    function updateNAV(uint256 newTotalAssetsUsdc, bytes32 reportHash) external onlyRole(ORACLE_ROLE) {
        if (newTotalAssetsUsdc == 0 && totalSupply() > DEAD_SHARES) revert ZeroAmount();

        uint256 oldNav = totalAssetsUsdc;
        if (oldNav > 0) {
            uint256 diff = newTotalAssetsUsdc > oldNav
                ? newTotalAssetsUsdc - oldNav
                : oldNav - newTotalAssetsUsdc;
            uint256 maxAllowedDiff = oldNav.mulDiv(maxNavDeltaBps, BPS_DENOMINATOR, Math.Rounding.Floor);
            if (diff > maxAllowedDiff) {
                revert NavDeltaExceeded(oldNav, newTotalAssetsUsdc, maxNavDeltaBps);
            }
        }

        totalAssetsUsdc = newTotalAssetsUsdc;
        latestReportHash = reportHash;
        lastNavUpdateTime = uint64(block.timestamp);

        emit NAVUpdated(oldNav, newTotalAssetsUsdc, currentNAVPerShare(), reportHash, false);
    }

    /**
     * @notice Admin override for legitimate NAV moves exceeding `±maxNavDeltaBps`.
     */
    function approveEmergencyNAV(uint256 newTotalAssetsUsdc, bytes32 reportHash) external onlyRole(ADMIN_ROLE) {
        if (newTotalAssetsUsdc == 0 && totalSupply() > DEAD_SHARES) revert ZeroAmount();
        uint256 oldNav = totalAssetsUsdc;

        totalAssetsUsdc = newTotalAssetsUsdc;
        latestReportHash = reportHash;
        lastNavUpdateTime = uint64(block.timestamp);

        emit NAVUpdated(oldNav, newTotalAssetsUsdc, currentNAVPerShare(), reportHash, true);
    }

    /**
     * @notice Updates oracle reference prices (in 6-decimal USDC per 1 whole token) for whitelisted tokens.
     *         Used by `swap` to enforce onchain slippage, single-position caps, and 24h volume limits.
     */
    function updateTokenPrices(address[] calldata tokens, uint256[] calldata pricesUsdc)
        external
        onlyRole(ORACLE_ROLE)
    {
        uint256 len = tokens.length;
        if (len == 0 || len != pricesUsdc.length) revert ZeroAmount();
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            if (!tokenConfigs[token].isWhitelisted) revert TokenNotWhitelisted(token);
            if (pricesUsdc[i] == 0) revert ZeroAmount();
            tokenConfigs[token].lastPriceUsdc = pricesUsdc[i];
            emit TokenPriceUpdated(token, pricesUsdc[i]);
        }
    }

    // =========================================================================
    // Manager Actions: Aggregator Swaps & Base Earn (Morpho) Buffer
    // =========================================================================

    /**
     * @notice Executes a swap between whitelisted tokens via the configured aggregator router.
     *         Enforces:
     *         1. Both `tokenIn` and `tokenOut` are actively whitelisted (timelock completed).
     *         2. Slippage does not exceed `maxSlippageBps` relative to oracle prices.
     *         3. `tokenOut` post-swap valuation does not exceed its `maxAllocationBps` of NAV.
     *         4. Vault cash buffer remains >= `minCashBufferBps` of NAV.
     *         5. 24h rolling swap volume does not exceed `maxDailySwapVolumeBps` of NAV.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes calldata aggregatorCalldata
    ) external onlyRole(MANAGER_ROLE) whenNotPaused nonReentrant returns (uint256 actualOut) {
        if (amountIn == 0 || minOut == 0) revert ZeroAmount();
        if (defaultAggregator == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert InvalidBpsValue(0);

        TokenConfig memory configIn = tokenConfigs[tokenIn];
        TokenConfig memory configOut = tokenConfigs[tokenOut];
        if (!configIn.isWhitelisted) revert TokenNotWhitelisted(tokenIn);
        if (!configOut.isWhitelisted) revert TokenNotWhitelisted(tokenOut);

        _requireFreshNav();

        // 1. Compute USDC value of input amount using oracle reference price
        uint256 usdcValueIn = tokenIn == address(usdc)
            ? amountIn
            : amountIn.mulDiv(configIn.lastPriceUsdc, 10 ** configIn.tokenDecimals, Math.Rounding.Ceil);

        // 2. Enforce 24-hour rolling swap volume cap
        if (block.timestamp >= currentSwapDayWindowStart + 1 days) {
            currentSwapDayWindowStart = uint64(block.timestamp);
            dailySwapVolumeUsdc = 0;
        }
        uint256 maxDailyVolume = totalAssetsUsdc.mulDiv(maxDailySwapVolumeBps, BPS_DENOMINATOR, Math.Rounding.Floor);
        if (dailySwapVolumeUsdc + usdcValueIn > maxDailyVolume) {
            revert DailySwapVolumeExceeded(dailySwapVolumeUsdc + usdcValueIn, maxDailyVolume);
        }
        dailySwapVolumeUsdc += usdcValueIn;

        // 3. Enforce maximum slippage bound against oracle reference price
        uint256 oracleExpectedOut = tokenOut == address(usdc)
            ? usdcValueIn
            : usdcValueIn.mulDiv(10 ** configOut.tokenDecimals, configOut.lastPriceUsdc, Math.Rounding.Floor);

        uint256 minAllowedBySlippage = oracleExpectedOut.mulDiv(
            BPS_DENOMINATOR - maxSlippageBps,
            BPS_DENOMINATOR,
            Math.Rounding.Floor
        );
        if (minOut < minAllowedBySlippage) {
            revert SlippageExceeded(minOut, minAllowedBySlippage);
        }

        // 4. Execute swap via aggregator with bounded approval (no infinite approvals)
        uint256 balanceBefore = IERC20(tokenOut).balanceOf(address(this));
        IERC20(tokenIn).forceApprove(defaultAggregator, amountIn);

        (bool success,) = defaultAggregator.call(aggregatorCalldata);
        IERC20(tokenIn).forceApprove(defaultAggregator, 0);
        if (!success) revert AggregatorCallFailed();

        uint256 balanceAfter = IERC20(tokenOut).balanceOf(address(this));
        if (balanceAfter <= balanceBefore) revert SlippageExceeded(0, minOut);
        actualOut = balanceAfter - balanceBefore;
        if (actualOut < minOut) revert SlippageExceeded(actualOut, minOut);

        // 5. Enforce single-position upper bound (for non-USDC assets)
        if (tokenOut != address(usdc)) {
            uint256 postSwapTokenValueUsdc = balanceAfter.mulDiv(
                configOut.lastPriceUsdc,
                10 ** configOut.tokenDecimals,
                Math.Rounding.Ceil
            );
            uint256 maxAllowedPositionUsdc = totalAssetsUsdc.mulDiv(
                configOut.maxAllocationBps,
                BPS_DENOMINATOR,
                Math.Rounding.Floor
            );
            if (postSwapTokenValueUsdc > maxAllowedPositionUsdc) {
                revert PositionLimitExceeded(tokenOut, postSwapTokenValueUsdc, maxAllowedPositionUsdc);
            }
        }

        // 6. Enforce minimum cash buffer ratio when spending USDC
        if (tokenIn == address(usdc)) {
            uint256 remainingCash = totalCashBufferUsdc();
            uint256 minRequiredCash = totalAssetsUsdc.mulDiv(
                minCashBufferBps,
                BPS_DENOMINATOR,
                Math.Rounding.Ceil
            );
            if (remainingCash < minRequiredCash) {
                revert CashBufferBelowMinimum(remainingCash, minRequiredCash);
            }
        }

        emit Swapped(tokenIn, tokenOut, amountIn, actualOut, usdcValueIn);
    }

    /**
     * @notice Deposits idle vault USDC into the Base Earn (Morpho) ERC-4626 vault.
     */
    function depositToYield(uint256 usdcAmount)
        external
        onlyRole(MANAGER_ROLE)
        whenNotPaused
        nonReentrant
        returns (uint256 sharesReceived)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (address(yieldVault) == address(0)) revert ZeroAddress();

        usdc.forceApprove(address(yieldVault), usdcAmount);
        sharesReceived = yieldVault.deposit(usdcAmount, address(this));
        usdc.forceApprove(address(yieldVault), 0);

        emit YieldDeposited(usdcAmount, sharesReceived);
    }

    /**
     * @notice Withdraws USDC from the Base Earn (Morpho) ERC-4626 vault back to CukkaVault.
     */
    function withdrawFromYield(uint256 usdcAmount)
        external
        onlyRole(MANAGER_ROLE)
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (address(yieldVault) == address(0)) revert ZeroAddress();

        sharesBurned = yieldVault.withdraw(usdcAmount, address(this), address(this));
        emit YieldWithdrawn(usdcAmount, sharesBurned);
    }

    // =========================================================================
    // Admin Actions: Timelocked Whitelist, Fee & Risk Parameters
    // =========================================================================

    /**
     * @notice Queues a token to be added to the whitelist after `whitelistTimelock` (default 24h).
     */
    function queueTokenWhitelist(address token, uint16 maxAllocationBps, uint256 initialPriceUsdc)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        if (initialPriceUsdc == 0) revert ZeroAmount();
        uint16 alloc = maxAllocationBps == 0 ? defaultMaxPositionBps : maxAllocationBps;
        if (alloc > BPS_DENOMINATOR) revert InvalidBpsValue(alloc);

        uint8 dec = IERC20Metadata(token).decimals();
        uint64 executableAt = uint64(block.timestamp) + whitelistTimelock;

        TokenConfig storage cfg = tokenConfigs[token];
        cfg.tokenDecimals = dec;
        cfg.queuedAt = uint64(block.timestamp);
        cfg.pendingMaxAllocBps = alloc;
        if (cfg.lastPriceUsdc == 0) {
            cfg.lastPriceUsdc = initialPriceUsdc;
        }

        emit TokenWhitelistQueued(token, alloc, executableAt);
    }

    /**
     * @notice Activates a queued token after the timelock period has elapsed.
     */
    function activateTokenWhitelist(address token) external onlyRole(ADMIN_ROLE) {
        TokenConfig storage cfg = tokenConfigs[token];
        if (cfg.queuedAt == 0) revert TimelockNotQueued();

        uint64 executableAt = cfg.queuedAt + whitelistTimelock;
        if (block.timestamp < executableAt) {
            revert TimelockNotExpired(uint64(block.timestamp), executableAt);
        }

        if (!cfg.isWhitelisted) {
            cfg.isWhitelisted = true;
            _whitelistedTokens.push(token);
        }
        cfg.maxAllocationBps = cfg.pendingMaxAllocBps;
        cfg.queuedAt = 0;
        cfg.pendingMaxAllocBps = 0;

        emit TokenWhitelistActivated(token, cfg.maxAllocationBps);
    }

    /**
     * @notice Immediately removes a token from the whitelist (no timelock required for removal).
     */
    function removeTokenFromWhitelist(address token) external onlyRole(ADMIN_ROLE) {
        if (token == address(usdc)) revert CannotRemoveBaseAsset();
        TokenConfig storage cfg = tokenConfigs[token];
        cfg.isWhitelisted = false;
        cfg.queuedAt = 0;
        cfg.pendingMaxAllocBps = 0;

        uint256 len = _whitelistedTokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (_whitelistedTokens[i] == token) {
                _whitelistedTokens[i] = _whitelistedTokens[len - 1];
                _whitelistedTokens.pop();
                break;
            }
        }

        emit TokenWhitelistRemoved(token);
    }

    /**
     * @notice Updates performance fee. Fee reductions take effect immediately; fee increases require timelock.
     */
    function setPerformanceFeeBps(uint16 newFeeBps) external onlyRole(ADMIN_ROLE) {
        if (newFeeBps > MAX_PERFORMANCE_FEE_BPS) revert InvalidBpsValue(newFeeBps);

        if (newFeeBps <= performanceFeeBps) {
            uint16 old = performanceFeeBps;
            performanceFeeBps = newFeeBps;
            pendingPerformanceFeeBps = 0;
            pendingFeeIncreaseExecutableAt = 0;
            emit PerformanceFeeUpdated(old, newFeeBps);
        } else {
            uint64 executableAt = uint64(block.timestamp) + whitelistTimelock;
            pendingPerformanceFeeBps = newFeeBps;
            pendingFeeIncreaseExecutableAt = executableAt;
            emit PerformanceFeeIncreaseQueued(newFeeBps, executableAt);
        }
    }

    /**
     * @notice Activates a queued performance fee increase after the timelock has elapsed.
     */
    function activatePerformanceFeeIncrease() external onlyRole(ADMIN_ROLE) {
        if (pendingFeeIncreaseExecutableAt == 0) revert TimelockNotQueued();
        if (block.timestamp < pendingFeeIncreaseExecutableAt) {
            revert TimelockNotExpired(uint64(block.timestamp), pendingFeeIncreaseExecutableAt);
        }

        uint16 old = performanceFeeBps;
        performanceFeeBps = pendingPerformanceFeeBps;
        pendingPerformanceFeeBps = 0;
        pendingFeeIncreaseExecutableAt = 0;

        emit PerformanceFeeUpdated(old, performanceFeeBps);
    }

    /**
     * @notice Updates risk guardrail parameters.
     */
    function setRiskParameters(
        uint16 _maxSlippageBps,
        uint16 _minCashBufferBps,
        uint16 _defaultMaxPositionBps,
        uint16 _maxNavDeltaBps,
        uint16 _maxDailySwapVolumeBps
    ) external onlyRole(ADMIN_ROLE) {
        if (
            _maxSlippageBps == 0 || _maxSlippageBps > MAX_SLIPPAGE_CAP_BPS ||
            _minCashBufferBps > 5_000 ||
            _defaultMaxPositionBps == 0 || _defaultMaxPositionBps > BPS_DENOMINATOR ||
            _maxNavDeltaBps == 0 || _maxNavDeltaBps > 5_000 ||
            _maxDailySwapVolumeBps == 0 || _maxDailySwapVolumeBps > BPS_DENOMINATOR
        ) revert InvalidBpsValue(0);

        maxSlippageBps = _maxSlippageBps;
        minCashBufferBps = _minCashBufferBps;
        defaultMaxPositionBps = _defaultMaxPositionBps;
        maxNavDeltaBps = _maxNavDeltaBps;
        maxDailySwapVolumeBps = _maxDailySwapVolumeBps;

        emit ParametersUpdated(
            _maxSlippageBps,
            _minCashBufferBps,
            _defaultMaxPositionBps,
            _maxNavDeltaBps,
            _maxDailySwapVolumeBps
        );
    }

    function setAggregator(address _newAggregator) external onlyRole(ADMIN_ROLE) {
        if (_newAggregator == address(0)) revert ZeroAddress();
        address old = defaultAggregator;
        defaultAggregator = _newAggregator;
        emit AggregatorUpdated(old, _newAggregator);
    }

    function setYieldVault(address _newYieldVault) external onlyRole(ADMIN_ROLE) {
        if (_newYieldVault == address(0)) revert ZeroAddress();
        address old = address(yieldVault);
        yieldVault = IERC4626Yield(_newYieldVault);
        emit YieldVaultUpdated(old, _newYieldVault);
    }

    function setFeeRecipient(address _newFeeRecipient) external onlyRole(ADMIN_ROLE) {
        if (_newFeeRecipient == address(0)) revert ZeroAddress();
        address old = feeRecipient;
        feeRecipient = _newFeeRecipient;
        emit FeeRecipientUpdated(old, _newFeeRecipient);
    }

    function setWhitelistTimelock(uint64 _newTimelock) external onlyRole(ADMIN_ROLE) {
        if (_newTimelock < 1 hours || _newTimelock > 7 days) revert InvalidBpsValue(_newTimelock);
        uint64 old = whitelistTimelock;
        whitelistTimelock = _newTimelock;
        emit WhitelistTimelockUpdated(old, _newTimelock);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    // =========================================================================
    // Internal Validation
    // =========================================================================

    function _requireFreshNav() internal view {
        if (totalSupply() > 0 && block.timestamp > lastNavUpdateTime + maxNavAge) {
            revert NavStale(lastNavUpdateTime, maxNavAge);
        }
    }
}
