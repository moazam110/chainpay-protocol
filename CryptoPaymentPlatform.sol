// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ============================================================
//  OpenZeppelin imports — install via:
//  npm install @openzeppelin/contracts  (v5.x)
// ============================================================
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title  CryptoPaymentPlatform
 * @notice Combined pool-vault ledger with invoice payment escrow and dispute
 *         resolution, designed for deployment on Arbitrum.
 * @dev    v1.6.0 — AWAITING_CONFIRMATION status: markComplete() no longer releases
 *         escrow immediately; payer has a configurable window (default 7 days) to
 *         call confirmCompletion() or raiseDispute(); after the window expires the
 *         merchant calls claimPayment(); if merchant never calls markComplete() the
 *         payer can call reclaimFunds() once the invoice dueDate has passed.
 *         raiseDispute() now only accepted on AWAITING_CONFIRMATION (not PAID).
 * @dev    v1.5.0 — fixes: receive() uses ContractMustBePaused, remove stray NatSpec char,
 *         removeExternalWallet requires permission, challenge-count cap with
 *         maxChallengesPerInvoice, payerAcknowledged flag on Invoice with
 *         acknowledgeInvoice(), calendar-month bucket via _getMonthKey(), P2P transfers
 *         use _calculateDefaultFee (no tier/override), minimum fee floor of 1,
 *         adminRefundToPayer accepts CHALLENGE_PENDING, editInvoice guards newMaxCycles,
 *         SubscriptionConfigUpdated event.
 * @dev    v1.4.1 — audit fixes: editInvoice access control (admin/employee can edit),
 *         adminReleaseToMerchant accepts CHALLENGE_PENDING, setChallengeWindow minimum
 *         1-day guard, FeeDeducted uses type(uint256).max for P2P transfer fees.
 * @dev    v1.4.0 — adds 8 new features: partial refund (Feature 1), invoice edit
 *         (Feature 2), dispute challenge window (Feature 3), P2P internal transfer
 *         (Feature 4), external wallet registration (Feature 5), external withdrawal
 *         permission (Feature 6), monthly receive limit (Feature 7), and user tier
 *         classification with tiered fee discounts (Feature 8).
 *
 * Architecture overview
 * ─────────────────────
 *  • All user funds are held inside this single contract.
 *  • Payments between users are pure ledger updates (5-10 k gas each).
 *  • Real ERC-20 / ETH transfers only occur on deposit and withdrawal.
 *  • Supported payment tokens: USDT, USDC, native ETH (address(0)).
 *
 * Role hierarchy
 * ──────────────
 *  Admin     → owner (Ownable); full privileges.
 *  Employee  → can resolve disputes and update per-user fees.
 *  Merchant  → can create / cancel / complete invoices.
 *  Payer     → any wallet; pays invoices and can raise disputes.
 *
 * Fee model
 * ─────────
 *  PERCENTAGE mode  → a single basis-point rate applied to every token.
 *  FLAT mode        → a per-token fixed amount stored in that token's native
 *                     units (e.g. 1 000 000 for 1 USDT at 6 decimals, or
 *                     5 × 10^14 wei for ~$1 of ETH). This avoids cross-token
 *                     decimal mismatch that a single flat value would cause.
 */
contract CryptoPaymentPlatform is Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    //  CONSTANTS
    // =========================================================================

    /// @notice Contract version — increment on each deployment.
    string public constant VERSION = "1.6.0";

    /// @notice Sentinel used in the internal ledger to represent native ETH.
    address public constant NATIVE_ETH = address(0);

    /// @notice Denominator for percentage fees expressed in basis points.
    ///         100 bps = 1 %, 10 000 bps = 100 %.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // =========================================================================
    //  ENUMS
    // =========================================================================

    /// @notice Full lifecycle of an invoice.
    enum InvoiceStatus {
        PENDING,                // created, awaiting first payment / first recurring cycle
        ACTIVE,                 // recurring only: ≥1 cycle completed, more remain
        PAID,                   // payer paid prepaid invoice; escrow locked
        AWAITING_CONFIRMATION,  // merchant marked complete; payer has window to confirm or dispute
        COMPLETED,              // payer confirmed, postpaid settled, timeout elapsed, or all cycles done
        CANCELLED,              // voided by merchant, payer, admin, or emergency shutdown
        DISPUTED,               // payer raised a dispute; escrow frozen
        CHALLENGE_PENDING       // dispute ruled merchant-wins; payer challenge window open
    }

    /// @notice Determines escrow behaviour and timing of fee deduction.
    enum PaymentType {
        PREPAID,  // payer pays before work; escrow held until markComplete
        POSTPAID  // merchant works first; payer pays on receipt, instant settle
    }

    /// @notice How the platform fee is computed.
    enum FeeType {
        PERCENTAGE, // value stored in basis points (e.g. 250 = 2.5 %)
        FLAT        // per-token flat amounts stored in separate mappings
    }

    /// @notice User loyalty tier that determines the fee discount applied when
    ///         the user acts as a merchant and has no per-user fee override.
    enum UserTier { STANDARD, SILVER, GOLD, PLATINUM }

    // =========================================================================
    //  STRUCTS
    // =========================================================================

    /**
     * @notice Complete invoice record stored on-chain.
     * @dev    `description` is a storage string; gas cost is acceptable for a
     *         production invoicing platform where invoice creation is infrequent.
     */
    struct Invoice {
        uint256       id;
        address       payer;
        address       merchant;
        address       token;             // NATIVE_ETH for ETH
        uint256       amount;            // gross amount (before fee)
        uint256       dueDate;           // overall invoice expiry (UNIX timestamp)
        string        description;
        PaymentType   paymentType;
        InvoiceStatus status;
        bool          isRecurring;
        uint256       recurringInterval; // seconds between cycles (0 if non-recurring)
        uint256       maxCycles;         // total cycles allowed (0 if non-recurring)
        uint256       completedCycles;   // cycles successfully triggered so far
        uint256       nextDueDate;       // earliest timestamp for the next cycle
        uint256       createdAt;
        bool          payerAcknowledged; // false after editInvoice; payer must re-ack before paying
    }

    /// @notice Mutable per-user metadata.
    struct UserConfig {
        bool    isEmployee;
        bool    isMerchant;
        bool    subscriptionActive;
        uint256 subscriptionExpiry; // UNIX timestamp
    }

    /**
     * @notice Configures fee mode — globally or per-merchant.
     * @dev    For FLAT type, the `value` field is unused; per-token amounts live
     *         in `defaultFlatFeePerToken` or `_userFlatFeePerToken`.
     */
    struct FeeConfig {
        FeeType feeType;
        uint256 value;  // bps if PERCENTAGE; ignored if FLAT
        bool    isSet;  // false means "fall back to global default"
    }

    /// @notice Payer-granted standing authorisation for recurring deductions.
    struct RecurringApproval {
        uint256 maxAmount;  // maximum deducted per single cycle
        uint256 totalLimit; // hard cap across all cycles (0 = unlimited)
        uint256 totalSpent; // cumulative amount deducted so far
        bool    active;
    }

    /// @notice Escrow record locked against a prepaid invoice ID.
    struct EscrowRecord {
        address token;
        uint256 amount;
        bool    frozen;   // true while a dispute is open; blocks release / refund
        bool    released; // true once funds have left escrow (prevents double-release)
    }

    // =========================================================================
    //  STATE — Pool Vault / Internal Ledger
    // =========================================================================

    /// @dev Primary ledger: user → token → balance (in token base units).
    mapping(address => mapping(address => uint256)) private _ledger;

    /// @notice Whether a token is accepted by the platform.
    mapping(address => bool) public supportedTokens;

    /**
     * @notice Decimal precision of each whitelisted token.
     * @dev    Stored when the token is added. Not used in contract math (flat fees
     *         are already stored in the token's native units) but exposed for
     *         frontend / SDK consumers so they can format amounts correctly without
     *         an extra RPC call to the token contract.
     */
    mapping(address => uint8) public tokenDecimals;

    // =========================================================================
    //  STATE — User Management
    // =========================================================================

    /// @dev Per-address configuration (merchant flag, subscription, etc.).
    mapping(address => UserConfig) private _userConfig;

    /// @notice Quick O(1) employee check used by the `onlyAdminOrEmployee` modifier.
    mapping(address => bool) public isEmployee;

    // =========================================================================
    //  STATE — Invoice Management
    // =========================================================================

    /// @dev Auto-incremented; starts at 1 so that id == 0 means "not found".
    uint256 private _invoiceCounter;

    /// @dev Primary invoice store keyed by invoice ID.
    mapping(uint256 => Invoice) private _invoices;

    /// @dev Index: merchant → list of invoice IDs they created.
    mapping(address => uint256[]) private _merchantInvoices;

    /// @dev Index: payer → list of invoice IDs assigned to them.
    mapping(address => uint256[]) private _payerInvoices;

    // =========================================================================
    //  STATE — Escrow
    // =========================================================================

    /// @dev Escrow records keyed by invoice ID (populated for PREPAID only).
    mapping(uint256 => EscrowRecord) private _escrow;

    // =========================================================================
    //  STATE — Recurring Payments
    // =========================================================================

    /// @dev payer → merchant → token → approval
    mapping(address => mapping(address => mapping(address => RecurringApproval)))
        private _recurringApprovals;

    /// @dev Tracks all merchants a payer has ever approved (for enumeration).
    ///      A merchant may appear even after revocation — callers must check
    ///      `getRecurringApproval` for the live active flag.
    mapping(address => address[]) private _payerApprovedMerchants;

    /// @dev De-duplication guard for `_payerApprovedMerchants`.
    mapping(address => mapping(address => bool)) private _payerMerchantTracked;

    // =========================================================================
    //  STATE — Fee Management
    // =========================================================================

    /// @notice Platform-wide default fee (mode + bps value for PERCENTAGE).
    FeeConfig public defaultFeeConfig;

    /**
     * @notice Global flat fee per token.
     * @dev    Only consulted when `defaultFeeConfig.feeType == FeeType.FLAT`.
     *         Values are in the token's own base units (e.g. 1_000_000 = 1 USDT
     *         at 6 decimals; 5e14 ≈ 0.0005 ETH at 18 decimals).
     */
    mapping(address => uint256) public defaultFlatFeePerToken;

    /// @dev Per-merchant fee override (mode + bps value for PERCENTAGE).
    mapping(address => FeeConfig) private _userFeeConfig;

    /**
     * @notice Per-merchant flat fee per token.
     * @dev    Only consulted when the merchant's FeeConfig is FLAT.
     *         Each token has its own slot so ETH and USDT can have independent
     *         flat amounts without any decimal-conversion arithmetic.
     */
    mapping(address => mapping(address => uint256)) private _userFlatFeePerToken;

    /// @notice Monthly subscription fee in `subscriptionToken` base units (0 = free).
    uint256 public subscriptionFee;

    /// @notice Token used for subscription payments.
    address public subscriptionToken;

    /// @notice How long a subscription remains valid after payment (default 30 days).
    uint256 public subscriptionDuration = 30 days;

    // =========================================================================
    //  STATE — Replay Protection
    // =========================================================================

    /// @notice Per-user nonce; incremented on each settled payment to prevent
    ///         replay of signed payment intents.
    mapping(address => uint256) public nonces;

    // =========================================================================
    //  STATE — Dispute Challenge Window  (Feature 3)
    // =========================================================================

    /// @notice Duration (seconds) of the payer challenge window after a
    ///         merchant-wins dispute ruling. Default: 30 days.
    uint256 public challengeWindowDuration = 30 days;

    /// @dev Invoice ID → deadline timestamp by which the payer may challenge.
    mapping(uint256 => uint256) private _disputeChallengeDeadline;

    /// @dev Invoice ID → number of times the payer has challenged a ruling.
    mapping(uint256 => uint256) private _challengeCount;

    /// @notice Maximum times a payer may challenge a single invoice's ruling.
    ///         Admin-configurable; default 1.
    uint256 public maxChallengesPerInvoice = 1;

    // =========================================================================
    //  STATE — Prepaid Confirmation Window  (v1.6.0)
    // =========================================================================

    /// @notice How long (seconds) the payer has to confirm or dispute after
    ///         the merchant calls markComplete(). Default: 7 days.
    uint256 public confirmationWindow = 7 days;

    /// @dev Invoice ID → deadline by which payer must confirm or dispute.
    mapping(uint256 => uint256) private _confirmationDeadline;

    // =========================================================================
    //  STATE — External Wallet Registration  (Feature 5)
    // =========================================================================

    /// @dev user → registered external wallet address (address(0) = none registered).
    mapping(address => address) private _externalWallet;

    // =========================================================================
    //  STATE — External Withdrawal Permission  (Feature 6)
    // =========================================================================

    /// @dev user → whether admin has granted external-withdrawal permission.
    ///      Only consulted when the user has a registered external wallet.
    mapping(address => bool) private _canWithdrawExternal;

    // =========================================================================
    //  STATE — Monthly Receive Limit  (Feature 7)
    // =========================================================================

    /// @notice Maximum fee-free family transfers a wallet may receive per 30-day
    ///         window. Admin-configurable; default 5.
    uint256 public freeReceiveLimit = 5;

    /// @dev recipient → monthKey → count of family-transfer receives.
    ///      monthKey = _getMonthKey(block.timestamp) → YYYYMM (calendar month).
    mapping(address => mapping(uint256 => uint256)) private _monthlyReceiveCount;

    // =========================================================================
    //  STATE — User Tier Classification  (Feature 8)
    // =========================================================================

    /// @dev user → loyalty tier (default STANDARD for all wallets).
    mapping(address => UserTier) private _userTier;

    /// @dev tier → fee discount in basis points applied on the base fee.
    ///      Defaults: STANDARD=0, SILVER=1000, GOLD=2000, PLATINUM=3000.
    mapping(UserTier => uint256) private _tierDiscount;

    // =========================================================================
    //  EVENTS
    // =========================================================================

    event UserRegistered(address indexed user, string role);
    event UserRoleUpdated(address indexed user, string newRole);
    event UserFeeTierUpdated(address indexed user, FeeConfig newFeeConfig);

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdrawal(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when admin whitelists a new token.
    event TokenAdded(address indexed token, uint8 decimals);

    /// @notice Emitted when admin removes a token from the whitelist.
    event TokenRemoved(address indexed token);

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed merchant,
        address indexed payer,
        uint256 amount,
        address token,
        PaymentType paymentType,
        bool isRecurring
    );
    event InvoiceCancelled(uint256 indexed invoiceId, string reason);
    event InvoicePaid(
        uint256 indexed invoiceId,
        address indexed payer,
        uint256 amount,
        uint256 timestamp
    );
    event InvoiceMarkedComplete(uint256 indexed invoiceId, address indexed merchant);
    event RecurringInvoiceTriggered(uint256 indexed invoiceId, uint256 cycleNumber);

    event FundsLocked(uint256 indexed invoiceId, uint256 amount);
    event FundsReleased(uint256 indexed invoiceId, address indexed merchant, uint256 netAmount);
    event FundsRefunded(uint256 indexed invoiceId, address indexed payer, uint256 amount);
    event FundsHeld(uint256 indexed invoiceId, string reason);

    event DisputeRaised(uint256 indexed invoiceId, address indexed payer, string reason);
    event DisputeResolved(uint256 indexed invoiceId, string decision, address indexed resolver);

    event FeeDeducted(uint256 indexed invoiceId, uint256 feeAmount, address token);
    event FeeConfigUpdated(address indexed user, FeeConfig newFeeConfig);

    /// @notice Emitted when a per-token flat fee is set (user == address(0) → global default).
    event FlatFeeUpdated(address indexed user, address indexed token, uint256 amount);

    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);
    event EmployeeAdded(address indexed employee);
    event EmployeeRemoved(address indexed employee);

    event SubscriptionPaid(address indexed merchant, uint256 expiry);
    event InternalTransfer(
        address indexed from,
        address indexed to,
        address indexed token,
        uint256 amount
    );

    // Feature 2 — Invoice Edit
    event InvoiceEdited(uint256 indexed invoiceId, address indexed editor, uint256 timestamp);

    // Feature 3 — Dispute Challenge Window
    event DisputeChallenged(uint256 indexed invoiceId, address indexed challenger, string evidence);

    // Feature 5 — External Wallet Registration
    event ExternalWalletRegistered(address indexed user, address indexed externalWallet);
    event ExternalWalletRemoved(address indexed user);

    // Feature 6 — External Withdrawal Permission
    event ExternalWithdrawPermissionUpdated(address indexed user, bool canWithdraw);

    // Feature 8 — User Tier Classification
    event UserTierUpdated(address indexed user, UserTier tier);

    // v1.5.0 additions
    event SubscriptionConfigUpdated(address indexed token, uint256 fee, uint256 duration);
    event InvoiceAcknowledged(uint256 indexed invoiceId, address indexed payer);

    // v1.6.0 additions
    event WorkSubmitted(uint256 indexed invoiceId, address indexed merchant);
    event InvoiceConfirmed(uint256 indexed invoiceId, address indexed payer);
    event FundsReclaimed(uint256 indexed invoiceId, address indexed payer);

    // =========================================================================
    //  CUSTOM ERRORS
    // =========================================================================

    error Unauthorized();
    error TokenNotSupported(address token);
    error InsufficientBalance(address user, address token, uint256 required, uint256 available);
    error InvoiceNotFound(uint256 invoiceId);
    error InvalidInvoiceStatus(uint256 invoiceId, InvoiceStatus current);
    error InvoiceDueDatePassed(uint256 invoiceId);
    error EscrowFrozen(uint256 invoiceId);
    error EscrowAlreadyReleased(uint256 invoiceId);
    error RecurringNotApproved();
    error RecurringLimitExceeded();
    error MaxCyclesReached(uint256 invoiceId);
    error TooEarlyForCycle(uint256 invoiceId, uint256 nextDue);
    error SubscriptionExpired(address merchant);
    error InvalidAmount();
    error InvalidFeeConfig();
    error TransactionExpired();
    error ZeroAddress();
    error ContractMustBePaused();
    // Feature 1 — Partial Refund
    error PartialRefundExceedsEscrow(uint256 invoiceId, uint256 requested, uint256 available);
    // Feature 2 — Invoice Edit
    error InvoiceNotEditable(uint256 invoiceId);
    // Feature 3 — Dispute Challenge Window
    error ChallengeWindowExpired(uint256 invoiceId, uint256 deadline);
    error ResolutionNotReady(uint256 invoiceId, uint256 readyAt);
    // Feature 4 — P2P Internal Transfer
    error CannotTransferToSelf();
    // Feature 5 — External Wallet Registration
    error CannotRegisterOwnAddress();
    // Feature 6 — External Withdrawal Permission
    error ExternalWithdrawNotApproved(address user);
    // v1.5.0 additions
    error MaxChallengesReached(uint256 invoiceId);
    error InvoiceNotAcknowledged(uint256 invoiceId);
    // v1.6.0 additions
    error ConfirmationWindowNotExpired(uint256 invoiceId, uint256 deadline);
    error ConfirmationWindowExpired(uint256 invoiceId, uint256 deadline);
    error InvoiceDueDateNotPassed(uint256 invoiceId);

    // =========================================================================
    //  MODIFIERS
    // =========================================================================

    /// @dev Restricts caller to the contract owner (admin).
    modifier onlyAdmin() {
        if (msg.sender != owner()) revert Unauthorized();
        _;
    }

    /// @dev Allows the admin or any registered employee.
    modifier onlyAdminOrEmployee() {
        if (msg.sender != owner() && !isEmployee[msg.sender]) revert Unauthorized();
        _;
    }

    /// @dev Reverts if `token` is not on the supported whitelist.
    modifier onlySupportedToken(address token) {
        if (!supportedTokens[token]) revert TokenNotSupported(token);
        _;
    }

    /// @dev Reverts if no invoice exists for `invoiceId`.
    modifier invoiceExists(uint256 invoiceId) {
        if (_invoices[invoiceId].id == 0) revert InvoiceNotFound(invoiceId);
        _;
    }

    // =========================================================================
    //  CONSTRUCTOR
    // =========================================================================

    /**
     * @notice Deploys the platform, whitelists initial tokens, and sets the
     *         default percentage-based fee.
     *
     * @param usdt               USDT contract address on Arbitrum (6 decimals).
     * @param usdc               USDC contract address on Arbitrum (6 decimals).
     * @param defaultFeeBps      Initial global fee in basis points (e.g. 250 = 2.5 %).
     * @param _subscriptionToken Token accepted for merchant subscription payments.
     * @param _subscriptionFee   Monthly subscription amount in token base units (0 = free).
     */
    constructor(
        address usdt,
        address usdc,
        uint256 defaultFeeBps,
        address _subscriptionToken,
        uint256 _subscriptionFee
    ) Ownable(msg.sender) {
        if (usdt == address(0) || usdc == address(0)) revert ZeroAddress();
        if (defaultFeeBps > BPS_DENOMINATOR) revert InvalidFeeConfig();

        // Whitelist: native ETH (18 decimals), USDT and USDC (6 decimals each on Arbitrum)
        supportedTokens[NATIVE_ETH] = true;
        tokenDecimals[NATIVE_ETH]   = 18;

        supportedTokens[usdt] = true;
        tokenDecimals[usdt]   = 6;

        supportedTokens[usdc] = true;
        tokenDecimals[usdc]   = 6;

        defaultFeeConfig = FeeConfig({
            feeType: FeeType.PERCENTAGE,
            value:   defaultFeeBps,
            isSet:   true
        });

        subscriptionToken = _subscriptionToken;
        subscriptionFee   = _subscriptionFee;

        // Feature 8: initialize default tier discounts
        _tierDiscount[UserTier.SILVER]   = 1_000; // 10% reduction on base fee
        _tierDiscount[UserTier.GOLD]     = 2_000; // 20% reduction on base fee
        _tierDiscount[UserTier.PLATINUM] = 3_000; // 30% reduction on base fee
    }

    // =========================================================================
    //  SECTION 1 — POOL VAULT: DEPOSITS
    // =========================================================================

    /**
     * @notice Deposit native ETH into the pool vault.
     * @dev    The ETH is held by the contract; only the caller's internal ledger
     *         balance is updated. No ETH leaves the contract until the user
     *         explicitly calls `withdrawETH`.
     */
    function depositETH()
        external
        payable
        nonReentrant
        whenNotPaused
    {
        if (msg.value == 0) revert InvalidAmount();
        _ledger[msg.sender][NATIVE_ETH] += msg.value;
        emit Deposit(msg.sender, NATIVE_ETH, msg.value);
    }

    /**
     * @notice Deposit an ERC-20 token into the pool vault.
     * @dev    Uses `safeTransferFrom`; credits only the amount actually received
     *         so that fee-on-transfer tokens are handled correctly.
     *
     * @param token  Token address (must be whitelisted; not address(0) — use depositETH).
     * @param amount Amount to deposit in token base units.
     */
    function depositToken(address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
    {
        // address(0) is the NATIVE_ETH sentinel; ETH deposits go through depositETH()
        if (token == NATIVE_ETH) revert TokenNotSupported(token);
        if (amount == 0) revert InvalidAmount();

        uint256 before   = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;

        _ledger[msg.sender][token] += received;
        emit Deposit(msg.sender, token, received);
    }

    // =========================================================================
    //  SECTION 2 — POOL VAULT: WITHDRAWALS
    // =========================================================================

    /**
     * @notice Withdraw native ETH from the internal ledger to the caller's wallet.
     * @dev    Follows checks-effects-interactions: ledger is decremented before
     *         the external call to prevent reentrancy.
     *
     * @param amount Amount of ETH to withdraw, in wei.
     */
    function withdrawETH(uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert InvalidAmount();
        uint256 bal = _ledger[msg.sender][NATIVE_ETH];
        if (bal < amount) revert InsufficientBalance(msg.sender, NATIVE_ETH, amount, bal);
        // Feature 6: users with a registered external wallet require admin permission to withdraw
        if (_externalWallet[msg.sender] != address(0) && !_canWithdrawExternal[msg.sender]) {
            revert ExternalWithdrawNotApproved(msg.sender);
        }

        // Effect before interaction (CEI)
        _ledger[msg.sender][NATIVE_ETH] -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit Withdrawal(msg.sender, NATIVE_ETH, amount);
    }

    /**
     * @notice Withdraw an ERC-20 token from the internal ledger to the caller's wallet.
     * @dev    Intentionally does NOT require the token to be currently whitelisted.
     *         If admin delists a token, existing holders must still be able to
     *         withdraw their balance. Gating on `onlySupportedToken` here would
     *         permanently trap funds for any user who held a delisted token.
     *
     * @param token  Token address (must not be address(0)).
     * @param amount Amount to withdraw in token base units.
     */
    function withdrawToken(address token, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (token == NATIVE_ETH) revert TokenNotSupported(token);
        if (amount == 0) revert InvalidAmount();
        uint256 bal = _ledger[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(msg.sender, token, amount, bal);
        // Feature 6: users with a registered external wallet require admin permission to withdraw
        if (_externalWallet[msg.sender] != address(0) && !_canWithdrawExternal[msg.sender]) {
            revert ExternalWithdrawNotApproved(msg.sender);
        }

        // Effect before interaction (CEI)
        _ledger[msg.sender][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdrawal(msg.sender, token, amount);
    }

    // =========================================================================
    //  SECTION 3 — USER MANAGEMENT
    // =========================================================================

    /**
     * @notice Admin registers a wallet as a merchant, enabling invoice creation.
     * @param merchant Address to register.
     */
    function registerMerchant(address merchant) external onlyAdmin {
        if (merchant == address(0)) revert ZeroAddress();
        _userConfig[merchant].isMerchant = true;
        emit UserRegistered(merchant, "MERCHANT");
    }

    /**
     * @notice Admin grants the employee role to a wallet.
     *         Employees can resolve disputes and update per-user fees.
     *
     * @param employee Wallet to promote.
     */
    function addEmployee(address employee) external onlyAdmin {
        if (employee == address(0)) revert ZeroAddress();
        isEmployee[employee]             = true;
        _userConfig[employee].isEmployee = true;
        emit EmployeeAdded(employee);
        emit UserRoleUpdated(employee, "EMPLOYEE");
    }

    /**
     * @notice Admin revokes the employee role from a wallet.
     * @param employee Wallet to demote.
     */
    function removeEmployee(address employee) external onlyAdmin {
        isEmployee[employee]             = false;
        _userConfig[employee].isEmployee = false;
        emit EmployeeRemoved(employee);
        emit UserRoleUpdated(employee, "PAYER");
    }

    // =========================================================================
    //  SECTION 4 — SUBSCRIPTION MANAGEMENT
    // =========================================================================

    /**
     * @notice Merchant pays their periodic subscription fee to keep invoice
     *         creation active. The fee is deducted from their internal ledger
     *         balance and credited to the admin (owner) ledger.
     *
     * @dev    If `subscriptionFee` is 0 the merchant is marked active at no cost.
     */
    function paySubscription() external nonReentrant whenNotPaused {
        UserConfig storage cfg = _userConfig[msg.sender];
        if (!cfg.isMerchant) revert Unauthorized();

        if (subscriptionFee == 0) {
            cfg.subscriptionActive = true;
            cfg.subscriptionExpiry = block.timestamp + subscriptionDuration;
            emit SubscriptionPaid(msg.sender, cfg.subscriptionExpiry);
            return;
        }

        uint256 bal = _ledger[msg.sender][subscriptionToken];
        if (bal < subscriptionFee) {
            revert InsufficientBalance(
                msg.sender, subscriptionToken, subscriptionFee, bal
            );
        }

        // Ledger update — no real token transfer between wallets
        _ledger[msg.sender][subscriptionToken] -= subscriptionFee;
        _ledger[owner()][subscriptionToken]    += subscriptionFee;

        cfg.subscriptionActive = true;
        cfg.subscriptionExpiry = block.timestamp + subscriptionDuration;

        emit SubscriptionPaid(msg.sender, cfg.subscriptionExpiry);
        emit InternalTransfer(msg.sender, owner(), subscriptionToken, subscriptionFee);
    }

    /**
     * @notice Returns whether a merchant's subscription is currently valid.
     * @param merchant Address to check.
     * @return True if the subscription is active and has not expired.
     */
    function isSubscriptionValid(address merchant) public view returns (bool) {
        UserConfig storage cfg = _userConfig[merchant];
        return cfg.subscriptionActive && cfg.subscriptionExpiry >= block.timestamp;
    }

    // =========================================================================
    //  SECTION 5 — INVOICE MANAGEMENT
    // =========================================================================

    /**
     * @notice Merchant creates a new invoice. Status starts as PENDING.
     *
     * @param payer             The customer's wallet address.
     * @param token             Payment token (USDT, USDC, or address(0) for ETH).
     * @param amount            Gross invoice amount in token base units.
     * @param dueDate           Overall expiry timestamp; no payments accepted after this.
     * @param description       Human-readable job description.
     * @param paymentType       PREPAID (escrow) or POSTPAID (instant settle).
     * @param isRecurring       Whether this invoice repeats on an interval.
     * @param recurringInterval Seconds between billing cycles (0 if non-recurring).
     * @param maxCycles         Maximum number of cycles to bill (0 if non-recurring).
     *
     * @return invoiceId        Auto-generated unique invoice identifier.
     */
    function createInvoice(
        address     payer,
        address     token,
        uint256     amount,
        uint256     dueDate,
        string calldata description,
        PaymentType paymentType,
        bool        isRecurring,
        uint256     recurringInterval,
        uint256     maxCycles
    )
        external
        whenNotPaused
        onlySupportedToken(token)
        returns (uint256 invoiceId)
    {
        if (!_userConfig[msg.sender].isMerchant) revert Unauthorized();
        if (subscriptionFee > 0 && !isSubscriptionValid(msg.sender)) {
            revert SubscriptionExpired(msg.sender);
        }
        if (payer == address(0))        revert ZeroAddress();
        if (payer == msg.sender)        revert Unauthorized(); // merchant cannot invoice themselves
        if (amount == 0)                revert InvalidAmount();
        if (dueDate <= block.timestamp) revert InvoiceDueDatePassed(0);
        if (isRecurring && (recurringInterval == 0 || maxCycles == 0)) {
            revert InvalidAmount();
        }

        unchecked { _invoiceCounter++; }
        invoiceId = _invoiceCounter;

        _invoices[invoiceId] = Invoice({
            id:                invoiceId,
            payer:             payer,
            merchant:          msg.sender,
            token:             token,
            amount:            amount,
            dueDate:           dueDate,
            description:       description,
            paymentType:       paymentType,
            status:            InvoiceStatus.PENDING,
            isRecurring:       isRecurring,
            recurringInterval: recurringInterval,
            maxCycles:         maxCycles,
            completedCycles:   0,
            nextDueDate:       isRecurring ? block.timestamp + recurringInterval : 0,
            createdAt:         block.timestamp,
            payerAcknowledged: true
        });

        _merchantInvoices[msg.sender].push(invoiceId);
        _payerInvoices[payer].push(invoiceId);

        emit InvoiceCreated(
            invoiceId, msg.sender, payer, amount, token, paymentType, isRecurring
        );
    }

    /**
     * @notice Cancel an invoice.
     *
     * @dev    Rules:
     *         • Merchant   → can cancel their own PENDING invoice only.
     *         • Admin / Employee → can cancel any PENDING or ACTIVE invoice.
     *         Invoices in ACTIVE state are mid-stream recurring invoices; only
     *         privileged roles can abort them to protect in-progress work.
     *
     * @param invoiceId Invoice to cancel.
     * @param reason    Human-readable cancellation reason (stored in event).
     */
    function cancelInvoice(uint256 invoiceId, string calldata reason)
        external
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        bool isMerchantOwner = msg.sender == inv.merchant;
        bool privileged      = msg.sender == owner() || isEmployee[msg.sender];

        if (inv.status == InvoiceStatus.PENDING) {
            if (!isMerchantOwner && !privileged) revert Unauthorized();
        } else if (inv.status == InvoiceStatus.ACTIVE) {
            // ACTIVE means recurring cycles are in progress; merchant cannot
            // self-cancel to prevent mid-stream abuse — admin / employee only.
            if (!privileged) revert Unauthorized();
        } else {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        inv.status = InvoiceStatus.CANCELLED;
        emit InvoiceCancelled(invoiceId, reason);
    }

    /**
     * @notice Payer rejects a PENDING invoice before making any payment.
     *
     * @param invoiceId Invoice to reject.
     * @param reason    Rejection reason (stored in event).
     */
    function rejectInvoice(uint256 invoiceId, string calldata reason)
        external
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != InvoiceStatus.PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        inv.status = InvoiceStatus.CANCELLED;
        emit InvoiceCancelled(invoiceId, reason);
    }

    // =========================================================================
    //  SECTION 6 — PREPAID PAYMENT FLOW
    // =========================================================================

    /**
     * @notice Payer pays a PREPAID invoice, locking the full amount in escrow.
     *
     * @dev    No platform fee is taken at this stage; the fee is deducted when
     *         the payer calls `confirmCompletion`, the merchant calls `claimPayment`
     *         after the confirmation window expires, or on dispute resolution.
     *         A `deadline` timestamp prevents stale signed payment intents.
     *
     * @param invoiceId Invoice to pay.
     * @param deadline  UNIX timestamp; reverts if `block.timestamp > deadline`.
     */
    function payPrepaidInvoice(uint256 invoiceId, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        if (block.timestamp > deadline) revert TransactionExpired();

        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer)                revert Unauthorized();
        if (inv.paymentType != PaymentType.PREPAID) revert Unauthorized();
        if (inv.status != InvoiceStatus.PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (!inv.payerAcknowledged) revert InvoiceNotAcknowledged(invoiceId);
        if (block.timestamp > inv.dueDate) revert InvoiceDueDatePassed(invoiceId);

        address token  = inv.token;
        uint256 amount = inv.amount;
        uint256 bal    = _ledger[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(msg.sender, token, amount, bal);

        // --- Effects ---
        _ledger[msg.sender][token] -= amount;

        _escrow[invoiceId] = EscrowRecord({
            token:    token,
            amount:   amount,
            frozen:   false,
            released: false
        });

        inv.status = InvoiceStatus.PAID;
        nonces[msg.sender]++;

        // --- Events ---
        emit FundsLocked(invoiceId, amount);
        emit InvoicePaid(invoiceId, msg.sender, amount, block.timestamp);
    }

    /**
     * @notice Merchant signals that work is done. Moves the invoice to
     *         AWAITING_CONFIRMATION and starts the payer confirmation window.
     *         Funds are NOT released yet — the payer must either call
     *         confirmCompletion() or raiseDispute() within the window, or the
     *         merchant can call claimPayment() after the window expires.
     *
     * @dev    Works on PAID status regardless of whether the invoice dueDate has
     *         passed, provided the payer has not already called reclaimFunds().
     *
     * @param invoiceId Prepaid invoice to mark as complete.
     */
    function markComplete(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.merchant) revert Unauthorized();
        if (inv.status != InvoiceStatus.PAID) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.frozen)   revert EscrowFrozen(invoiceId);
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        _confirmationDeadline[invoiceId] = block.timestamp + confirmationWindow;
        inv.status = InvoiceStatus.AWAITING_CONFIRMATION;
        emit WorkSubmitted(invoiceId, msg.sender);
    }

    /**
     * @notice Payer confirms that work is satisfactory, releasing escrowed funds
     *         to the merchant after deducting the platform fee.
     *
     * @param invoiceId Invoice in AWAITING_CONFIRMATION state.
     */
    function confirmCompletion(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != InvoiceStatus.AWAITING_CONFIRMATION) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = false;
        _releaseEscrowToMerchant(invoiceId, inv.merchant, inv.payer, esc);
        inv.status = InvoiceStatus.COMPLETED;
        emit InvoiceConfirmed(invoiceId, msg.sender);
        emit InvoiceMarkedComplete(invoiceId, inv.merchant);
    }

    /**
     * @notice Payer reclaims their locked escrow when the merchant never called
     *         markComplete() and the invoice dueDate has passed.
     *
     * @dev    Only valid on PAID status after dueDate. Once the merchant calls
     *         markComplete() the status moves to AWAITING_CONFIRMATION and this
     *         function is no longer available.
     *
     * @param invoiceId Prepaid invoice in PAID state past its dueDate.
     */
    function reclaimFunds(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != InvoiceStatus.PAID) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (block.timestamp <= inv.dueDate) revert InvoiceDueDateNotPassed(invoiceId);

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = false;
        _refundEscrowToPayer(invoiceId, inv.payer, esc);
        inv.status = InvoiceStatus.CANCELLED;
        emit FundsReclaimed(invoiceId, msg.sender);
        emit InvoiceCancelled(invoiceId, "Merchant did not complete before due date");
    }

    /**
     * @notice Merchant claims payment after the payer's confirmation window has
     *         expired without a confirmCompletion() or raiseDispute() call.
     *
     * @param invoiceId Invoice in AWAITING_CONFIRMATION state past the confirmation deadline.
     */
    function claimPayment(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.merchant) revert Unauthorized();
        if (inv.status != InvoiceStatus.AWAITING_CONFIRMATION) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (block.timestamp <= _confirmationDeadline[invoiceId]) {
            revert ConfirmationWindowNotExpired(invoiceId, _confirmationDeadline[invoiceId]);
        }

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = false;
        _releaseEscrowToMerchant(invoiceId, inv.merchant, inv.payer, esc);
        inv.status = InvoiceStatus.COMPLETED;
        emit InvoiceMarkedComplete(invoiceId, inv.merchant);
    }

    // =========================================================================
    //  SECTION 7 — POSTPAID PAYMENT FLOW
    // =========================================================================

    /**
     * @notice Payer settles a POSTPAID invoice in a single step.
     *
     * @dev    No escrow is created; the fee is deducted immediately and the net
     *         amount is credited to the merchant's internal ledger. Invoice moves
     *         directly to COMPLETED.
     *
     * @param invoiceId Invoice to settle.
     * @param deadline  UNIX timestamp; reverts if `block.timestamp > deadline`.
     */
    function payPostpaidInvoice(uint256 invoiceId, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        if (block.timestamp > deadline) revert TransactionExpired();

        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer)                 revert Unauthorized();
        if (inv.paymentType != PaymentType.POSTPAID) revert Unauthorized();
        if (inv.status != InvoiceStatus.PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (!inv.payerAcknowledged) revert InvoiceNotAcknowledged(invoiceId);

        address token  = inv.token;
        uint256 amount = inv.amount;
        uint256 bal    = _ledger[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(msg.sender, token, amount, bal);

        (uint256 fee, uint256 net) = _calculateFee(inv.merchant, amount, token);

        // --- Effects ---
        _ledger[msg.sender][token]   -= amount;
        _ledger[inv.merchant][token] += net;
        _ledger[owner()][token]      += fee;

        inv.status = InvoiceStatus.COMPLETED;
        nonces[msg.sender]++;

        // --- Events ---
        emit FeeDeducted(invoiceId, fee, token);
        emit InternalTransfer(msg.sender, inv.merchant, token, net);
        emit InvoicePaid(invoiceId, msg.sender, amount, block.timestamp);
        emit InvoiceMarkedComplete(invoiceId, inv.merchant);
    }

    // =========================================================================
    //  SECTION 8 — RECURRING PAYMENT FLOW
    // =========================================================================

    /**
     * @notice Payer pre-authorises the merchant to pull recurring payments for
     *         a specific token.
     *
     * @param merchant    Merchant address allowed to trigger pulls.
     * @param token       Token to approve.
     * @param maxPerCycle Maximum amount that can be deducted per cycle.
     * @param totalLimit  Hard cap across all cycles combined (0 = unlimited).
     */
    function approveRecurring(
        address merchant,
        address token,
        uint256 maxPerCycle,
        uint256 totalLimit
    )
        external
        whenNotPaused
        onlySupportedToken(token)
    {
        if (merchant == address(0)) revert ZeroAddress();
        if (maxPerCycle == 0)       revert InvalidAmount();

        _recurringApprovals[msg.sender][merchant][token] = RecurringApproval({
            maxAmount:  maxPerCycle,
            totalLimit: totalLimit,
            totalSpent: 0,
            active:     true
        });

        // Track merchant for enumeration — only add once per payer-merchant pair
        if (!_payerMerchantTracked[msg.sender][merchant]) {
            _payerMerchantTracked[msg.sender][merchant] = true;
            _payerApprovedMerchants[msg.sender].push(merchant);
        }
    }

    /**
     * @notice Payer revokes a previously granted recurring approval.
     *         Any cycle not yet triggered is immediately blocked.
     *
     * @param merchant Merchant whose approval is being revoked.
     * @param token    Token for which approval is revoked.
     */
    function revokeRecurring(address merchant, address token) external {
        _recurringApprovals[msg.sender][merchant][token].active = false;
    }

    /**
     * @notice Merchant triggers the next billing cycle on a recurring invoice.
     *
     * @dev    Checks (in order):
     *         1. Caller is the invoice merchant.
     *         2. Invoice is recurring.
     *         3. Invoice status is PENDING (first cycle) or ACTIVE (subsequent).
     *         4. Max cycles not yet reached.
     *         5. Current time is past `nextDueDate`.
     *         6. Current time is before the invoice's overall `dueDate`.
     *         7. Payer has an active approval covering this merchant + token.
     *         8. Payer approval limits are not exceeded.
     *         9. Payer has sufficient ledger balance.
     *
     * @param invoiceId Recurring invoice to advance.
     */
    function triggerRecurring(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.merchant) revert Unauthorized();
        if (!inv.isRecurring)           revert Unauthorized();

        // Allow both PENDING (first cycle) and ACTIVE (subsequent cycles)
        if (inv.status != InvoiceStatus.PENDING && inv.status != InvoiceStatus.ACTIVE) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        if (inv.completedCycles >= inv.maxCycles) revert MaxCyclesReached(invoiceId);
        if (block.timestamp < inv.nextDueDate)    revert TooEarlyForCycle(invoiceId, inv.nextDueDate);

        // Overall invoice expiry check: no further cycles past the due date
        if (block.timestamp > inv.dueDate) revert InvoiceDueDatePassed(invoiceId);

        address payer  = inv.payer;
        address token  = inv.token;
        uint256 amount = inv.amount;

        RecurringApproval storage approval = _recurringApprovals[payer][msg.sender][token];
        if (!approval.active)            revert RecurringNotApproved();
        if (approval.maxAmount < amount) revert RecurringLimitExceeded();
        if (
            approval.totalLimit > 0 &&
            approval.totalSpent + amount > approval.totalLimit
        ) revert RecurringLimitExceeded();

        uint256 payerBal = _ledger[payer][token];
        if (payerBal < amount) revert InsufficientBalance(payer, token, amount, payerBal);

        (uint256 fee, uint256 net) = _calculateFee(inv.merchant, amount, token);

        // --- Effects ---
        _ledger[payer][token]        -= amount;
        _ledger[inv.merchant][token] += net;
        _ledger[owner()][token]      += fee;

        approval.totalSpent += amount;
        inv.completedCycles++;
        inv.nextDueDate     += inv.recurringInterval;

        if (inv.completedCycles >= inv.maxCycles) {
            inv.status = InvoiceStatus.COMPLETED;
            emit InvoiceMarkedComplete(invoiceId, inv.merchant);
        } else {
            // Mark ACTIVE so the merchant cannot self-cancel mid-stream
            inv.status = InvoiceStatus.ACTIVE;
        }

        // --- Events ---
        emit FeeDeducted(invoiceId, fee, token);
        emit InternalTransfer(payer, inv.merchant, token, net);
        emit RecurringInvoiceTriggered(invoiceId, inv.completedCycles);
    }

    // =========================================================================
    //  SECTION 9 — DISPUTE SYSTEM
    // =========================================================================

    /**
     * @notice Payer raises a dispute after the merchant has called markComplete()
     *         but before the payer has confirmed or the confirmation window has
     *         expired. Freezes the escrow so neither party can access the funds.
     *
     * @dev    Only valid on AWAITING_CONFIRMATION. The payer cannot dispute while
     *         still on PAID status — they must wait for the merchant to signal
     *         completion first, or use reclaimFunds() once the dueDate has passed.
     *
     * @param invoiceId Invoice in AWAITING_CONFIRMATION state.
     * @param reason    Human-readable explanation of the dispute.
     */
    function raiseDispute(uint256 invoiceId, string calldata reason)
        external
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer)                revert Unauthorized();
        if (inv.paymentType != PaymentType.PREPAID) revert Unauthorized();
        if (inv.status != InvoiceStatus.AWAITING_CONFIRMATION) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (block.timestamp > _confirmationDeadline[invoiceId]) {
            revert ConfirmationWindowExpired(invoiceId, _confirmationDeadline[invoiceId]);
        }

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = true;
        inv.status = InvoiceStatus.DISPUTED;

        emit DisputeRaised(invoiceId, msg.sender, reason);
        emit FundsHeld(invoiceId, reason);
    }

    /**
     * @notice Admin or employee resolves an open dispute, directing escrowed
     *         funds to the winning party.
     *
     * @param invoiceId         Disputed invoice to resolve.
     * @param releaseToMerchant true  → release net amount to merchant.
     *                          false → full refund to payer (no fee charged).
     * @param reason            Resolution rationale (stored in event).
     */
    function resolveDispute(
        uint256 invoiceId,
        bool    releaseToMerchant,
        string calldata reason
    )
        external
        nonReentrant
        whenNotPaused
        onlyAdminOrEmployee
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.status != InvoiceStatus.DISPUTED) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        if (releaseToMerchant) {
            // Feature 3: instead of releasing immediately, open a payer challenge window.
            // Funds remain frozen until the deadline; payer may call challengeDispute()
            // within the window. After the deadline, anyone calls finalizeResolution().
            _disputeChallengeDeadline[invoiceId] = block.timestamp + challengeWindowDuration;
            inv.status = InvoiceStatus.CHALLENGE_PENDING;
            emit DisputeResolved(invoiceId, "CHALLENGE_PENDING", msg.sender);
        } else {
            esc.frozen = false;
            _refundEscrowToPayer(invoiceId, inv.payer, esc);
            emit DisputeResolved(invoiceId, "REFUND", msg.sender);
            inv.status = InvoiceStatus.COMPLETED;
        }
    }

    /**
     * @notice Admin or employee force-releases escrow to the merchant outside
     *         the formal dispute flow (e.g. after off-chain resolution).
     *
     * @param invoiceId Invoice whose escrow is to be released to merchant.
     */
    function adminReleaseToMerchant(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        onlyAdminOrEmployee
        invoiceExists(invoiceId)
    {
        Invoice storage inv      = _invoices[invoiceId];
        // Only statuses with a populated escrow record are accepted.
        if (inv.status != InvoiceStatus.PAID &&
            inv.status != InvoiceStatus.AWAITING_CONFIRMATION &&
            inv.status != InvoiceStatus.DISPUTED &&
            inv.status != InvoiceStatus.CHALLENGE_PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = false;
        _releaseEscrowToMerchant(invoiceId, inv.merchant, inv.payer, esc);
        inv.status = InvoiceStatus.COMPLETED;
        emit InvoiceMarkedComplete(invoiceId, inv.merchant);
    }

    /**
     * @notice Admin or employee refunds some or all of the escrowed amount to
     *         the payer. Supports both full and partial refunds.
     *
     * @dev    If `refundAmount` equals the full escrow: full refund, no fee.
     *         If `refundAmount` is less: the remainder is released to the merchant
     *         after deducting the platform fee on the remainder only.
     *
     * @param invoiceId    Invoice whose escrow is to be (partially) refunded.
     * @param refundAmount Amount to return to the payer (≤ escrow amount).
     */
    function adminRefundToPayer(uint256 invoiceId, uint256 refundAmount)
        external
        nonReentrant
        whenNotPaused
        onlyAdminOrEmployee
        invoiceExists(invoiceId)
    {
        Invoice storage inv      = _invoices[invoiceId];
        // Accepts any status where escrow is still populated.
        if (inv.status != InvoiceStatus.PAID &&
            inv.status != InvoiceStatus.AWAITING_CONFIRMATION &&
            inv.status != InvoiceStatus.DISPUTED &&
            inv.status != InvoiceStatus.CHALLENGE_PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);
        if (refundAmount > esc.amount) {
            revert PartialRefundExceedsEscrow(invoiceId, refundAmount, esc.amount);
        }

        esc.frozen = false;

        if (refundAmount == esc.amount) {
            // Full refund — entire escrow returned to payer, no fee deducted.
            _refundEscrowToPayer(invoiceId, inv.payer, esc);
        } else {
            // Partial refund: `refundAmount` to payer; remainder to merchant minus fee.
            address token     = esc.token;
            uint256 remainder = esc.amount - refundAmount;

            esc.released = true;

            _ledger[inv.payer][token] += refundAmount;
            emit FundsRefunded(invoiceId, inv.payer, refundAmount);

            (uint256 fee, uint256 net) = _calculateFee(inv.merchant, remainder, token);
            _ledger[inv.merchant][token] += net;
            _ledger[owner()][token]      += fee;
            emit FeeDeducted(invoiceId, fee, token);
            emit FundsReleased(invoiceId, inv.merchant, net);
        }

        inv.status = InvoiceStatus.COMPLETED;
    }

    // =========================================================================
    //  SECTION 10 — INTERNAL ESCROW HELPERS
    // =========================================================================

    /**
     * @dev Releases escrowed funds to the merchant after deducting the platform
     *      fee. Marks the escrow as released to prevent double-release.
     *      `_calculateFee` receives the token address for accurate flat-fee lookup.
     */
    function _releaseEscrowToMerchant(
        uint256 invoiceId,
        address merchant,
        address payer,
        EscrowRecord storage esc
    ) internal {
        uint256 amount = esc.amount;
        address token  = esc.token;

        (uint256 fee, uint256 net) = _calculateFee(merchant, amount, token);

        esc.released = true;

        _ledger[merchant][token] += net;
        _ledger[owner()][token]  += fee;

        emit FeeDeducted(invoiceId, fee, token);
        emit FundsReleased(invoiceId, merchant, net);
        emit InternalTransfer(payer, merchant, token, net);
    }

    /**
     * @dev Returns the full escrowed amount to the payer with no fee deducted.
     *      Marks the escrow as released to prevent double-refund.
     */
    function _refundEscrowToPayer(
        uint256 invoiceId,
        address payer,
        EscrowRecord storage esc
    ) internal {
        uint256 amount = esc.amount;
        address token  = esc.token;

        esc.released = true;

        _ledger[payer][token] += amount;

        emit FundsRefunded(invoiceId, payer, amount);
    }

    // =========================================================================
    //  SECTION 11 — FEE MANAGEMENT
    // =========================================================================

    /**
     * @notice Admin switches the global fee mode and sets the percentage value.
     *
     * @dev    For FLAT mode: calling this sets `defaultFeeConfig.feeType = FLAT`
     *         but the `value` field is ignored. Call `setDefaultFlatFee` per token
     *         to configure the actual per-token flat amounts.
     *         For PERCENTAGE mode: `value` is in basis points (max 10 000).
     *
     * @param feeType PERCENTAGE or FLAT.
     * @param value   Basis points for PERCENTAGE; ignored for FLAT.
     */
    function setDefaultFee(FeeType feeType, uint256 value) external onlyAdmin {
        if (feeType == FeeType.PERCENTAGE && value > BPS_DENOMINATOR) revert InvalidFeeConfig();
        defaultFeeConfig = FeeConfig({ feeType: feeType, value: value, isSet: true });
        emit FeeConfigUpdated(address(0), defaultFeeConfig);
    }

    /**
     * @notice Admin sets the global flat fee for a specific token.
     *         Also switches the global fee mode to FLAT if not already set.
     *
     * @dev    Store amounts in the token's own base units:
     *           USDT / USDC (6 decimals): 1_000_000 = 1 token
     *           ETH (18 decimals):        5e14 ≈ 0.0005 ETH
     *         This avoids any cross-decimal arithmetic inside the contract.
     *
     * @param token  Token address (must be supported).
     * @param amount Flat fee in token base units (0 = no fee for this token).
     */
    function setDefaultFlatFee(address token, uint256 amount)
        external
        onlyAdmin
        onlySupportedToken(token)
    {
        defaultFlatFeePerToken[token] = amount;
        // Auto-switch mode to FLAT so _calculateFee picks up the new values
        defaultFeeConfig.feeType = FeeType.FLAT;
        defaultFeeConfig.isSet   = true;
        emit FlatFeeUpdated(address(0), token, amount);
        emit FeeConfigUpdated(address(0), defaultFeeConfig);
    }

    /**
     * @notice Admin or employee sets a custom fee tier for a specific merchant
     *         (PERCENTAGE mode), overriding the global default for that wallet.
     *
     * @param user    Merchant wallet to override.
     * @param feeType PERCENTAGE or FLAT. For FLAT, also call `setUserFlatFee`.
     * @param value   Basis points for PERCENTAGE; ignored for FLAT.
     */
    function setUserFee(address user, FeeType feeType, uint256 value)
        external
        onlyAdminOrEmployee
    {
        if (user == address(0)) revert ZeroAddress();
        if (feeType == FeeType.PERCENTAGE && value > BPS_DENOMINATOR) revert InvalidFeeConfig();

        _userFeeConfig[user] = FeeConfig({ feeType: feeType, value: value, isSet: true });

        emit FeeConfigUpdated(user, _userFeeConfig[user]);
        emit UserFeeTierUpdated(user, _userFeeConfig[user]);
    }

    /**
     * @notice Admin or employee sets a per-token flat fee override for a specific
     *         merchant. Automatically marks that merchant's fee mode as FLAT.
     *
     * @dev    Multiple tokens can each have their own flat amount for the same
     *         merchant. Each call only updates the slot for the given token, so
     *         calling once for USDT and once for ETH gives independent amounts.
     *
     *         Example for a merchant billed 0.5 USDT flat on every invoice:
     *           setUserFlatFee(merchant, usdtAddress, 500_000)
     *
     * @param user   Merchant wallet to override.
     * @param token  Token address (must be supported).
     * @param amount Flat fee in token base units.
     */
    function setUserFlatFee(address user, address token, uint256 amount)
        external
        onlyAdminOrEmployee
        onlySupportedToken(token)
    {
        if (user == address(0)) revert ZeroAddress();

        _userFlatFeePerToken[user][token] = amount;

        // Ensure the user's override is in FLAT mode so _calculateFee routes correctly
        _userFeeConfig[user].feeType = FeeType.FLAT;
        _userFeeConfig[user].isSet   = true;

        emit FlatFeeUpdated(user, token, amount);
        emit UserFeeTierUpdated(user, _userFeeConfig[user]);
    }

    /**
     * @notice Admin or employee removes a per-user fee override, reverting the
     *         merchant to the global default fee.
     * @dev    Any per-token flat fee entries remain in storage but are ignored
     *         while `isSet == false`.
     *
     * @param user Merchant wallet to reset.
     */
    function removeUserFee(address user) external onlyAdminOrEmployee {
        delete _userFeeConfig[user];
        emit FeeConfigUpdated(user, defaultFeeConfig);
    }

    /**
     * @notice Admin reconfigures the merchant subscription parameters.
     *
     * @param token    Token used for subscription payments.
     * @param fee      Monthly fee in token base units (0 = free platform).
     * @param duration Validity period in seconds.
     */
    function setSubscriptionConfig(address token, uint256 fee, uint256 duration)
        external
        onlyAdmin
    {
        // Prevent merchants from being locked out with an undepositable token.
        // If fee > 0 the token must be whitelisted so merchants can actually hold
        // a balance in it. When fee == 0 the token field is irrelevant.
        if (fee > 0 && !supportedTokens[token]) revert TokenNotSupported(token);

        subscriptionToken    = token;
        subscriptionFee      = fee;
        subscriptionDuration = duration;
        emit SubscriptionConfigUpdated(token, fee, duration);
    }

    /**
     * @dev Computes the platform fee and net amount for a payment.
     *
     *      Resolution order:
     *        1. If merchant has a per-user override (isSet == true):
     *           – PERCENTAGE → bps from the override.
     *           – FLAT       → per-token flat amount from `_userFlatFeePerToken`.
     *        2. Otherwise, use the global default:
     *           – PERCENTAGE → bps from `defaultFeeConfig`.
     *           – FLAT       → per-token flat amount from `defaultFlatFeePerToken`.
     *
     *      Flat amounts are in the same token's base units, so no decimal
     *      conversion is needed and cross-token mismatch is impossible.
     *
     *      A flat fee that exceeds the full invoice amount is capped at the
     *      invoice amount (merchant receives zero but is not debited further).
     *
     * @param merchant Address whose fee tier is looked up.
     * @param amount   Gross payment amount in token base units.
     * @param token    Token address being paid (used for flat-fee lookup).
     * @return fee     Platform fee to credit to admin.
     * @return net     Merchant net after fee deduction.
     */
    function _calculateFee(address merchant, uint256 amount, address token)
        internal
        view
        returns (uint256 fee, uint256 net)
    {
        FeeConfig storage userCfg = _userFeeConfig[merchant];

        if (userCfg.isSet) {
            // Per-user override takes full precedence; tier discount does not apply.
            if (userCfg.feeType == FeeType.PERCENTAGE) {
                fee = (amount * userCfg.value) / BPS_DENOMINATOR;
            } else {
                // FLAT: use the per-token flat amount for this merchant
                uint256 flat = _userFlatFeePerToken[merchant][token];
                fee = flat > amount ? amount : flat;
            }
        } else {
            // No per-user override — compute base fee then apply tier discount.
            uint256 baseFee;
            if (defaultFeeConfig.feeType == FeeType.PERCENTAGE) {
                baseFee = (amount * defaultFeeConfig.value) / BPS_DENOMINATOR;
            } else {
                // FLAT: use the global per-token flat amount
                uint256 flat = defaultFlatFeePerToken[token];
                baseFee = flat > amount ? amount : flat;
            }

            // Feature 8: apply tier discount (e.g. GOLD 2000 bps = 20% off the fee).
            uint256 discount = _tierDiscount[_userTier[merchant]];
            if (discount > 0) {
                uint256 reduction = (baseFee * discount) / BPS_DENOMINATOR;
                fee = baseFee - reduction;
            } else {
                fee = baseFee;
            }
        }

        // Minimum fee floor: if the configured rate is non-zero but the computed
        // fee rounded down to zero (tiny amounts), charge at least 1 base unit.
        if (fee == 0 && amount > 0) {
            bool hasRate;
            if (userCfg.isSet) {
                hasRate = userCfg.feeType == FeeType.PERCENTAGE
                    ? userCfg.value > 0
                    : _userFlatFeePerToken[merchant][token] > 0;
            } else {
                hasRate = defaultFeeConfig.feeType == FeeType.PERCENTAGE
                    ? defaultFeeConfig.value > 0
                    : defaultFlatFeePerToken[token] > 0;
            }
            if (hasRate) fee = 1;
        }

        net = amount - fee;
    }

    /**
     * @dev Computes the platform fee using ONLY the global default fee config,
     *      ignoring any per-user overrides and tier discounts. Used for P2P
     *      internal transfers so the base platform rate always applies regardless
     *      of the sender's tier or custom merchant rate.
     *
     * @param amount Gross payment amount in token base units.
     * @param token  Token address (used for flat-fee lookup).
     * @return fee   Platform fee.
     * @return net   Recipient net after fee deduction.
     */
    function _calculateDefaultFee(uint256 amount, address token)
        internal
        view
        returns (uint256 fee, uint256 net)
    {
        if (defaultFeeConfig.feeType == FeeType.PERCENTAGE) {
            fee = (amount * defaultFeeConfig.value) / BPS_DENOMINATOR;
        } else {
            uint256 flat = defaultFlatFeePerToken[token];
            fee = flat > amount ? amount : flat;
        }

        // Minimum fee floor: charge at least 1 base unit when the rate is non-zero.
        if (fee == 0 && amount > 0) {
            bool hasRate = defaultFeeConfig.feeType == FeeType.PERCENTAGE
                ? defaultFeeConfig.value > 0
                : defaultFlatFeePerToken[token] > 0;
            if (hasRate) fee = 1;
        }

        net = amount - fee;
    }

    /**
     * @dev Derives a calendar month key (YYYYMM) from a Unix timestamp using
     *      pure integer arithmetic (Howard Hinnant's civil-from-days algorithm).
     *      The key resets on the 1st of each calendar month.
     *
     * @param timestamp Unix timestamp in seconds.
     * @return          Month key as `year * 100 + month` (e.g. 202601 for Jan 2026).
     */
    function _getMonthKey(uint256 timestamp) internal pure returns (uint256) {
        uint256 z   = timestamp / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y   = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp  = (5 * doy + 2) / 153;
        uint256 m   = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y++;
        return y * 100 + m;
    }

    // =========================================================================
    //  SECTION 12 — ADMIN CONTROLS
    // =========================================================================

    /**
     * @notice Admin pauses the entire contract (emergency brake).
     *         All state-changing functions are blocked while paused.
     */
    function pause() external onlyAdmin {
        _pause();
    }

    /**
     * @notice Admin unpauses the contract after resolving an emergency.
     */
    function unpause() external onlyAdmin whenPaused {
        _unpause();
    }

    /**
     * @notice Admin adds a new token to the supported whitelist and stores its
     *         decimal precision for frontend consumers.
     *
     * @dev    address(0) is intentionally blocked here. Native ETH is already
     *         whitelisted in the constructor and is handled exclusively through
     *         `depositETH` / `withdrawETH`. Allowing address(0) through this path
     *         would risk overwriting the ETH decimal entry and causing confusion.
     *         To re-enable ETH after an accidental `removeSupportedToken(address(0))`
     *         call, have the admin call `supportedTokens` setter or redeploy.
     *         In practice, ETH should never be removed.
     *
     * @param token    ERC-20 token address to whitelist.
     * @param decimals Decimal precision of the token (e.g. 6 for USDT / USDC,
     *                 18 for WETH). Must be provided by admin; the contract does
     *                 not call `decimals()` on the token to avoid dependency on
     *                 IERC20Metadata and potential non-standard implementations.
     */
    function addSupportedToken(address token, uint8 decimals) external onlyAdmin {
        // address(0) is reserved as the NATIVE_ETH sentinel — block re-addition
        // via this path to prevent accidental overwrite of the ETH decimal entry.
        if (token == address(0)) revert ZeroAddress();

        supportedTokens[token] = true;
        tokenDecimals[token]   = decimals;

        emit TokenAdded(token, decimals);
    }

    /**
     * @notice Admin removes a token from the supported whitelist.
     *         Existing ledger balances in that token are unaffected; holders
     *         can still withdraw via `withdrawToken` even after delisting.
     *
     * @dev    address(0) / NATIVE_ETH is explicitly blocked. Delisting ETH would
     *         prevent new ETH-denominated invoices and recurring approvals from
     *         being created (both gate on `onlySupportedToken`). Deposits and
     *         withdrawals of ETH would still work because they do not check
     *         `supportedTokens`, but the broken invoice path is enough reason to
     *         guard this. ETH should never be delisted; redeploy if needed.
     *
     * @param token Token to delist.
     */
    function removeSupportedToken(address token) external onlyAdmin {
        if (token == NATIVE_ETH) revert ZeroAddress();
        supportedTokens[token] = false;
        emit TokenRemoved(token);
    }

    /**
     * @notice Transfers contract ownership to a new admin address.
     * @dev    Overrides `Ownable.transferOwnership` to emit `AdminTransferred`.
     *
     * @param newOwner New admin wallet address.
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        address old = owner();
        super.transferOwnership(newOwner);
        emit AdminTransferred(old, newOwner);
    }

    // =========================================================================
    //  SECTION 13 — EMERGENCY WITHDRAWAL (ADMIN, PAUSED ONLY)
    // =========================================================================

    /**
     * @notice Emergency: admin returns all user balances AND unresolved escrow
     *         funds back to their rightful owners. Only callable when paused.
     *
     * @dev    Two separate loops handle different fund pools:
     *
     *         Ledger loop — iterates `users × tokens` and sends each user's
     *         internal ledger balance directly to their wallet.
     *
     *         Escrow loop — iterates `escrowInvoiceIds`; for each unreleased
     *         escrow record the full amount is refunded to the original payer.
     *         If an ETH send fails, the amount is credited back to the payer's
     *         ledger so the user can withdraw it manually once unpaused (or in
     *         a second emergency call). ERC-20 failures bubble up via SafeERC20.
     *
     *         To avoid unbounded loops the caller supplies both lists. Iterate
     *         in batches if the user base is very large.
     *
     * @param users           List of user wallet addresses whose ledger balances
     *                        should be swept.
     * @param tokens          List of token addresses to process per user
     *                        (include address(0) for ETH).
     * @param escrowInvoiceIds List of invoice IDs that have active (unreleased)
     *                        escrow records to be refunded to the payer.
     */
    function emergencyWithdrawAll(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata escrowInvoiceIds
    )
        external
        nonReentrant
        onlyAdmin
    {
        if (!paused()) revert ContractMustBePaused();

        // ── Ledger sweep ────────────────────────────────────────────────────
        for (uint256 i = 0; i < users.length; ) {
            address user = users[i];

            for (uint256 j = 0; j < tokens.length; ) {
                address token = tokens[j];
                uint256 bal   = _ledger[user][token];

                if (bal > 0) {
                    _ledger[user][token] = 0;

                    if (token == NATIVE_ETH) {
                        (bool ok, ) = user.call{value: bal}("");
                        if (!ok) {
                            // Restore so admin can retry for this user
                            _ledger[user][token] = bal;
                        } else {
                            emit Withdrawal(user, token, bal);
                        }
                    } else {
                        IERC20(token).safeTransfer(user, bal);
                        emit Withdrawal(user, token, bal);
                    }
                }
                unchecked { j++; }
            }
            unchecked { i++; }
        }

        // ── Escrow sweep ─────────────────────────────────────────────────────
        for (uint256 k = 0; k < escrowInvoiceIds.length; ) {
            uint256 invoiceId = escrowInvoiceIds[k];
            EscrowRecord storage esc = _escrow[invoiceId];

            // Skip if already released or if no escrow was ever created
            if (!esc.released && esc.amount > 0) {
                Invoice storage inv = _invoices[invoiceId];
                address payer  = inv.payer;
                address token  = esc.token;
                uint256 amount = esc.amount;

                // Mark released and unfreeze before any external interaction
                esc.released = true;
                esc.frozen   = false;

                if (token == NATIVE_ETH) {
                    (bool ok, ) = payer.call{value: amount}("");
                    if (!ok) {
                        // Credit to payer's ledger as a fallback — they can
                        // withdraw manually after the contract is unpaused.
                        _ledger[payer][token] += amount;
                        // Do NOT restore esc.released to prevent double-release
                    } else {
                        emit FundsRefunded(invoiceId, payer, amount);
                    }
                } else {
                    IERC20(token).safeTransfer(payer, amount);
                    emit FundsRefunded(invoiceId, payer, amount);
                }

                // Terminate the invoice cleanly
                inv.status = InvoiceStatus.CANCELLED;
                emit InvoiceCancelled(invoiceId, "Emergency shutdown");
            }

            unchecked { k++; }
        }
    }

    // =========================================================================
    //  SECTION 14 — VIEW / QUERY FUNCTIONS
    // =========================================================================

    /**
     * @notice Returns the full Invoice struct for a given invoice ID.
     * @param invoiceId Invoice to query.
     * @return          The complete Invoice record.
     */
    function getInvoice(uint256 invoiceId)
        external
        view
        invoiceExists(invoiceId)
        returns (Invoice memory)
    {
        return _invoices[invoiceId];
    }

    /**
     * @notice Returns the internal ledger balance for a user and token.
     *
     * @param user  Wallet address to query.
     * @param token Token address; use address(0) for ETH.
     * @return      Balance in token base units.
     */
    function balanceOf(address user, address token) external view returns (uint256) {
        return _ledger[user][token];
    }

    /**
     * @notice Returns all invoice IDs that a merchant has created.
     * @param merchant Merchant wallet address.
     * @return         Array of invoice IDs (chronological order).
     */
    function getMerchantInvoices(address merchant) external view returns (uint256[] memory) {
        return _merchantInvoices[merchant];
    }

    /**
     * @notice Returns all invoice IDs assigned to a payer.
     * @param payer Payer wallet address.
     * @return      Array of invoice IDs (chronological order).
     */
    function getPayerInvoices(address payer) external view returns (uint256[] memory) {
        return _payerInvoices[payer];
    }

    /**
     * @notice Returns the recurring approval between a payer, merchant, and token.
     *
     * @param payer    Payer address.
     * @param merchant Merchant address.
     * @param token    Token address.
     *
     * @return active       Whether the approval is currently active.
     * @return maxPerCycle  Maximum deductible per cycle.
     * @return totalLimit   Total budget cap (0 = unlimited).
     * @return totalSpent   Cumulative amount deducted under this approval.
     * @return remaining    Budget remaining (type(uint256).max if unlimited).
     */
    function getRecurringApproval(address payer, address merchant, address token)
        external
        view
        returns (
            bool    active,
            uint256 maxPerCycle,
            uint256 totalLimit,
            uint256 totalSpent,
            uint256 remaining
        )
    {
        RecurringApproval storage a = _recurringApprovals[payer][merchant][token];
        active      = a.active;
        maxPerCycle = a.maxAmount;
        totalLimit  = a.totalLimit;
        totalSpent  = a.totalSpent;
        remaining   = (a.totalLimit == 0)
            ? type(uint256).max
            : (a.totalSpent < a.totalLimit ? a.totalLimit - a.totalSpent : 0);
    }

    /**
     * @notice Returns the list of merchant addresses that a payer has ever
     *         approved for recurring payments (including revoked approvals).
     * @dev    Callers should cross-reference with `getRecurringApproval` to
     *         determine which approvals are still active.
     *
     * @param payer Payer wallet address.
     * @return      Array of merchant addresses (insertion order, deduplicated per
     *              payer-merchant pair via `_payerMerchantTracked`).
     */
    function getPayerApprovedMerchants(address payer)
        external
        view
        returns (address[] memory)
    {
        return _payerApprovedMerchants[payer];
    }

    /**
     * @notice Returns escrow details for a prepaid invoice.
     *
     * @param invoiceId Invoice to inspect.
     * @return token    Escrowed token address.
     * @return amount   Escrowed amount (gross, before fee).
     * @return frozen   True if a dispute is blocking release.
     * @return released True if escrow has already been settled.
     */
    function getEscrow(uint256 invoiceId)
        external
        view
        returns (
            address token,
            uint256 amount,
            bool    frozen,
            bool    released
        )
    {
        EscrowRecord storage e = _escrow[invoiceId];
        return (e.token, e.amount, e.frozen, e.released);
    }

    /**
     * @notice Returns the timestamp by which the payer must confirm or dispute
     *         after the merchant calls `markComplete()`. Returns 0 if the invoice
     *         has not yet entered the AWAITING_CONFIRMATION state.
     *
     * @param invoiceId Invoice to query.
     */
    function getConfirmationDeadline(uint256 invoiceId) external view returns (uint256) {
        return _confirmationDeadline[invoiceId];
    }

    /**
     * @notice Returns the effective fee configuration for a given merchant.
     *
     * @param merchant       Merchant to query.
     * @return feeType       PERCENTAGE or FLAT.
     * @return value         Fee value (bps if PERCENTAGE; 0 if FLAT — see flat
     *                       fee lookups via `getEffectiveFlatFee`).
     * @return isUserOverride True if a per-user override is active.
     */
    function getEffectiveFee(address merchant)
        external
        view
        returns (FeeType feeType, uint256 value, bool isUserOverride)
    {
        FeeConfig storage cfg = _userFeeConfig[merchant];
        if (cfg.isSet) {
            return (cfg.feeType, cfg.value, true);
        }
        return (defaultFeeConfig.feeType, defaultFeeConfig.value, false);
    }

    /**
     * @notice Returns the effective flat fee for a merchant–token pair.
     * @dev    Returns 0 if the active fee mode is PERCENTAGE (not applicable).
     *
     * @param merchant Merchant to query.
     * @param token    Token address.
     * @return amount  Flat fee in token base units.
     */
    function getEffectiveFlatFee(address merchant, address token)
        external
        view
        returns (uint256 amount)
    {
        FeeConfig storage cfg = _userFeeConfig[merchant];
        if (cfg.isSet && cfg.feeType == FeeType.FLAT) {
            return _userFlatFeePerToken[merchant][token];
        }
        if (!cfg.isSet && defaultFeeConfig.feeType == FeeType.FLAT) {
            return defaultFlatFeePerToken[token];
        }
        return 0;
    }

    /**
     * @notice Returns token whitelist status and decimal precision.
     *
     * @param token  Token address to inspect.
     * @return supported True if whitelisted.
     * @return decimals  Decimal precision stored at whitelist time.
     */
    function getTokenInfo(address token)
        external
        view
        returns (bool supported, uint8 decimals)
    {
        return (supportedTokens[token], tokenDecimals[token]);
    }

    /**
     * @notice Returns the user configuration struct for any wallet.
     * @param user Address to inspect.
     * @return     UserConfig (employee flag, merchant flag, subscription state).
     */
    function getUserConfig(address user) external view returns (UserConfig memory) {
        return _userConfig[user];
    }

    /**
     * @notice Returns the total number of invoices ever created.
     * @return Invoice counter (equals the last-issued invoice ID).
     */
    function totalInvoices() external view returns (uint256) {
        return _invoiceCounter;
    }

    /**
     * @notice Simulates the fee split for a hypothetical payment without
     *         executing it. Useful for frontend quoting.
     *
     * @dev    Passes the token address to `_calculateFee` so that flat-fee
     *         lookups return the correct per-token amount rather than a generic
     *         value that would be meaningless across tokens with different decimals.
     *
     * @param merchant Merchant address (determines which fee tier applies).
     * @param amount   Hypothetical gross payment amount in token base units.
     * @param token    Token that would be used for payment.
     * @return fee     Platform fee portion.
     * @return net     Merchant net portion.
     */
    function previewFee(address merchant, uint256 amount, address token)
        external
        view
        returns (uint256 fee, uint256 net)
    {
        return _calculateFee(merchant, amount, token);
    }

    // =========================================================================
    //  SECTION 15 — INVOICE EDIT  (Feature 2)
    // =========================================================================

    /**
     * @notice Merchant edits a PENDING invoice before the payer has paid.
     *         Non-recurring fields (`amount`, `dueDate`, `description`) are always
     *         editable. `recurringInterval` and `maxCycles` may only be changed on
     *         recurring invoices. Pass 0 / empty string for fields you do not wish
     *         to update.
     *
     * @param invoiceId            Invoice to modify (must be PENDING).
     * @param newAmount            New gross amount in token base units (0 = keep current).
     * @param newDueDate           New overall expiry timestamp (0 = keep current).
     * @param newDescription       New description (empty string = keep current).
     * @param newRecurringInterval New cycle interval in seconds (0 = keep current).
     * @param newMaxCycles         New maximum number of cycles (0 = keep current).
     */
    function editInvoice(
        uint256 invoiceId,
        uint256 newAmount,
        uint256 newDueDate,
        string calldata newDescription,
        uint256 newRecurringInterval,
        uint256 newMaxCycles
    )
        external
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        bool isMerchantOwner = msg.sender == inv.merchant;
        bool privileged      = msg.sender == owner() || isEmployee[msg.sender];
        if (!isMerchantOwner && !privileged) revert Unauthorized();
        if (inv.status != InvoiceStatus.PENDING) revert InvoiceNotEditable(invoiceId);

        if (newAmount != 0)                    inv.amount = newAmount;
        if (newDueDate != 0) {
            if (newDueDate <= block.timestamp) revert InvoiceDueDatePassed(invoiceId);
            inv.dueDate = newDueDate;
        }
        if (bytes(newDescription).length > 0) inv.description = newDescription;
        if (inv.isRecurring) {
            if (newRecurringInterval != 0) inv.recurringInterval = newRecurringInterval;
            if (newMaxCycles != 0) {
                if (newMaxCycles < inv.completedCycles) revert InvalidAmount();
                inv.maxCycles = newMaxCycles;
            }
        }

        // Signal payer that the invoice has changed; they must call acknowledgeInvoice
        // before payPrepaidInvoice will succeed.
        inv.payerAcknowledged = false;

        emit InvoiceEdited(invoiceId, msg.sender, block.timestamp);
    }

    /**
     * @notice Payer acknowledges an edited invoice, re-enabling payment.
     *
     * @dev    After `editInvoice` is called, `payerAcknowledged` is set to false
     *         and `payPrepaidInvoice` will revert until the payer calls this function.
     *         Only the invoice's assigned payer may call it, and only while PENDING.
     *
     * @param invoiceId Invoice to acknowledge.
     */
    function acknowledgeInvoice(uint256 invoiceId)
        external
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != InvoiceStatus.PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        inv.payerAcknowledged = true;
        emit InvoiceAcknowledged(invoiceId, msg.sender);
    }

    // =========================================================================
    //  SECTION 16 — DISPUTE CHALLENGE WINDOW  (Feature 3)
    // =========================================================================

    /**
     * @notice Payer contests a merchant-wins dispute ruling while the challenge
     *         window is still open. Resets the invoice to DISPUTED status so the
     *         admin or employee can re-examine the case.
     *
     * @param invoiceId Invoice in CHALLENGE_PENDING state.
     * @param evidence  Text or reference supporting the challenge.
     */
    function challengeDispute(uint256 invoiceId, string calldata evidence)
        external
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (msg.sender != inv.payer) revert Unauthorized();
        if (inv.status != InvoiceStatus.CHALLENGE_PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        if (block.timestamp > _disputeChallengeDeadline[invoiceId]) {
            revert ChallengeWindowExpired(invoiceId, _disputeChallengeDeadline[invoiceId]);
        }
        if (_challengeCount[invoiceId] >= maxChallengesPerInvoice) {
            revert MaxChallengesReached(invoiceId);
        }

        // Escrow remains frozen; only status changes so admin can re-adjudicate.
        _challengeCount[invoiceId]++;
        inv.status = InvoiceStatus.DISPUTED;
        emit DisputeChallenged(invoiceId, msg.sender, evidence);
        emit FundsHeld(invoiceId, evidence);
    }

    /**
     * @notice Finalises a merchant-wins ruling once the payer challenge window
     *         has expired without a challenge. Releases escrowed funds to the
     *         merchant after deducting the platform fee.
     *
     * @dev    Callable by anyone after the deadline — the outcome is immutable
     *         at that point and no privileged role is required.
     *
     * @param invoiceId Invoice in CHALLENGE_PENDING state whose deadline has passed.
     */
    function finalizeResolution(uint256 invoiceId)
        external
        nonReentrant
        whenNotPaused
        invoiceExists(invoiceId)
    {
        Invoice storage inv = _invoices[invoiceId];
        if (inv.status != InvoiceStatus.CHALLENGE_PENDING) {
            revert InvalidInvoiceStatus(invoiceId, inv.status);
        }
        uint256 deadline = _disputeChallengeDeadline[invoiceId];
        if (block.timestamp <= deadline) revert ResolutionNotReady(invoiceId, deadline);

        EscrowRecord storage esc = _escrow[invoiceId];
        if (esc.released) revert EscrowAlreadyReleased(invoiceId);

        esc.frozen = false;
        _releaseEscrowToMerchant(invoiceId, inv.merchant, inv.payer, esc);
        inv.status = InvoiceStatus.COMPLETED;
        emit DisputeResolved(invoiceId, "FINALIZED", msg.sender);
    }

    /**
     * @notice Admin sets the duration of the payer challenge window.
     * @param duration New window length in seconds (e.g. 7 days, 30 days).
     */
    function setChallengeWindow(uint256 duration) external onlyAdmin {
        if (duration < 1 days) revert InvalidAmount();
        challengeWindowDuration = duration;
    }

    /**
     * @notice Admin sets the maximum number of times a payer may challenge a
     *         single invoice's dispute ruling (default 1).
     * @param max New cap (0 = no challenges allowed after the first ruling).
     */
    function setMaxChallenges(uint256 max) external onlyAdmin {
        maxChallengesPerInvoice = max;
    }

    /**
     * @notice Admin sets the confirmation window duration — how long the payer
     *         has to call confirmCompletion() or raiseDispute() after the merchant
     *         calls markComplete(). Default: 7 days. Minimum: 1 day.
     * @param duration New window length in seconds.
     */
    function setConfirmationWindow(uint256 duration) external onlyAdmin {
        if (duration < 1 days) revert InvalidAmount();
        confirmationWindow = duration;
    }

    // =========================================================================
    //  SECTION 17 — P2P INTERNAL TRANSFER  (Feature 4 + Feature 7)
    // =========================================================================

    /**
     * @notice Transfers an internal ledger balance from the caller to another user.
     *         Platform fee applies; the `isFamilyTransfer` flag enables fee-free
     *         transfers up to the recipient's monthly `freeReceiveLimit`.
     *
     * @dev    Fee is computed using the global default fee config only (no per-user
     *         overrides, no tier discounts) via `_calculateDefaultFee`. The monthly
     *         receive count is keyed to the *recipient* using a calendar month key
     *         (YYYYMM) and is always incremented for family transfers regardless of
     *         whether the fee-free threshold has been reached.
     *
     * @param recipient        Destination wallet (must differ from caller).
     * @param token            Supported token (including NATIVE_ETH / address(0)).
     * @param amount           Gross amount to deduct from the caller's ledger.
     * @param isFamilyTransfer When true: treated as a family / friends transfer.
     *                         No fee is charged if the recipient has not yet reached
     *                         their monthly free-receive limit; the count is always
     *                         incremented for tracking.
     */
    function transferToUser(
        address recipient,
        address token,
        uint256 amount,
        bool isFamilyTransfer
    )
        external
        nonReentrant
        whenNotPaused
        onlySupportedToken(token)
    {
        if (recipient == msg.sender)  revert CannotTransferToSelf();
        if (recipient == address(0))  revert ZeroAddress();
        if (amount == 0)              revert InvalidAmount();

        uint256 bal = _ledger[msg.sender][token];
        if (bal < amount) revert InsufficientBalance(msg.sender, token, amount, bal);

        uint256 fee;
        uint256 net;

        if (isFamilyTransfer) {
            uint256 monthKey = _getMonthKey(block.timestamp);
            if (_monthlyReceiveCount[recipient][monthKey] < freeReceiveLimit) {
                // Under the limit — fee-free
                fee = 0;
                net = amount;
            } else {
                (fee, net) = _calculateDefaultFee(amount, token);
            }
            // Always increment so the limit is enforced regardless of fee result
            _monthlyReceiveCount[recipient][monthKey]++;
        } else {
            (fee, net) = _calculateDefaultFee(amount, token);
        }

        // --- Effects (CEI) ---
        _ledger[msg.sender][token]  -= amount;
        _ledger[recipient][token]   += net;
        if (fee > 0) _ledger[owner()][token] += fee;

        nonces[msg.sender]++;

        // --- Events ---
        emit InternalTransfer(msg.sender, recipient, token, net);
        // type(uint256).max signals a P2P transfer fee rather than an invoice fee.
        if (fee > 0) emit FeeDeducted(type(uint256).max, fee, token);
    }

    /**
     * @notice Admin sets the maximum number of fee-free family transfers a wallet
     *         may receive per 30-day window.
     * @param limit New monthly limit (0 = always charge a fee on family transfers).
     */
    function setFreeReceiveLimit(uint256 limit) external onlyAdmin {
        freeReceiveLimit = limit;
    }

    /**
     * @notice Returns how many family transfers a wallet has received in the
     *         current 30-day window.
     * @param user Recipient wallet to query.
     * @return     Count for the current 30-day window.
     */
    function getMonthlyReceiveCount(address user) external view returns (uint256) {
        return _monthlyReceiveCount[user][_getMonthKey(block.timestamp)];
    }

    // =========================================================================
    //  SECTION 18 — EXTERNAL WALLET & WITHDRAWAL PERMISSION  (Features 5 & 6)
    // =========================================================================

    /**
     * @notice Registers an external wallet for the caller. Once registered, all
     *         calls to `withdrawETH` / `withdrawToken` require admin-granted
     *         external-withdrawal permission before they succeed.
     *
     * @param externalWallet External wallet to associate (not zero, not self).
     */
    function registerExternalWallet(address externalWallet) external {
        if (externalWallet == address(0)) revert ZeroAddress();
        if (externalWallet == msg.sender) revert CannotRegisterOwnAddress();
        _externalWallet[msg.sender] = externalWallet;
        emit ExternalWalletRegistered(msg.sender, externalWallet);
    }

    /**
     * @notice Removes the caller's registered external wallet, restoring
     *         unrestricted withdrawal access.
     */
    function removeExternalWallet() external {
        // Require admin-granted permission before the user can deregister their
        // external wallet. This ensures admin has reviewed the account before the
        // withdrawal gate is removed.
        if (!_canWithdrawExternal[msg.sender]) revert ExternalWithdrawNotApproved(msg.sender);
        _externalWallet[msg.sender] = address(0);
        emit ExternalWalletRemoved(msg.sender);
    }

    /**
     * @notice Returns the external wallet registered for a given user.
     * @param user Wallet to query.
     * @return     Registered external wallet (address(0) if none).
     */
    function getExternalWallet(address user) external view returns (address) {
        return _externalWallet[user];
    }

    /**
     * @notice Admin grants or revokes external-withdrawal permission for a user.
     *         Only effective for users who have a registered external wallet.
     *
     * @param user  User wallet to update.
     * @param value true = allow withdrawal; false = block withdrawal.
     */
    function setExternalWithdrawPermission(address user, bool value) external onlyAdmin {
        if (user == address(0)) revert ZeroAddress();
        _canWithdrawExternal[user] = value;
        emit ExternalWithdrawPermissionUpdated(user, value);
    }

    /**
     * @notice Returns whether a user holds admin-granted external-withdrawal permission.
     * @param user Wallet to query.
     * @return     True if permission has been granted.
     */
    function canWithdrawExternal(address user) external view returns (bool) {
        return _canWithdrawExternal[user];
    }

    // =========================================================================
    //  SECTION 19 — USER TIER CLASSIFICATION  (Feature 8)
    // =========================================================================

    /**
     * @notice Admin or employee assigns a loyalty tier to a user. The tier
     *         determines the fee discount applied when the user acts as a merchant
     *         and has no per-user fee override configured.
     *
     * @param user User wallet to classify.
     * @param tier New tier (STANDARD, SILVER, GOLD, or PLATINUM).
     */
    function setUserTier(address user, UserTier tier) external onlyAdminOrEmployee {
        if (user == address(0)) revert ZeroAddress();
        _userTier[user] = tier;
        emit UserTierUpdated(user, tier);
    }

    /**
     * @notice Admin sets the fee discount for a specific tier.
     *         The discount is expressed in basis points and is applied to the
     *         computed base fee (not the invoice amount).
     *
     * @dev    Example: base fee = 100 tokens, GOLD discount = 2 000 bps →
     *         reduction = 100 × 2000 / 10000 = 20 → effective fee = 80 tokens.
     *
     * @param tier        Tier to configure.
     * @param discountBps Discount in basis points (max 10 000 = 100% of the fee).
     */
    function setTierDiscount(UserTier tier, uint256 discountBps) external onlyAdmin {
        if (discountBps > BPS_DENOMINATOR) revert InvalidFeeConfig();
        _tierDiscount[tier] = discountBps;
    }

    /**
     * @notice Returns the current loyalty tier for a given user.
     * @param user Wallet to query.
     * @return     UserTier enum value.
     */
    function getUserTier(address user) external view returns (UserTier) {
        return _userTier[user];
    }

    // =========================================================================
    //  RECEIVE — plain ETH sends credited as deposits
    // =========================================================================

    /**
     * @dev Treats any direct ETH transfer to the contract as a deposit for the
     *      sender. Allows users to fund their ledger with a plain ETH send
     *      without calling `depositETH` explicitly.
     */
    receive() external payable {
        // Block deposits while paused so the pause mechanism covers all fund entry points.
        if (paused()) revert ContractMustBePaused();
        if (msg.value > 0) {
            _ledger[msg.sender][NATIVE_ETH] += msg.value;
            emit Deposit(msg.sender, NATIVE_ETH, msg.value);
        }
    }
}
