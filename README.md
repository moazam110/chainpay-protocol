# CryptoPaymentPlatform

A production-grade Solidity smart contract for the Arbitrum blockchain that combines a gas-efficient pool-vault internal ledger with a full invoice payment system, escrow management, and on-chain dispute resolution — all in a single deployable contract.

> **Who this README is for:** Developers who are comfortable with JavaScript, REST APIs, and databases but may not have deep blockchain or Solidity experience. Where blockchain concepts appear, plain-English explanations are provided before the technical detail.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Key Concepts (Plain English)](#2-key-concepts-plain-english)
3. [Architecture](#3-architecture)
4. [Roles and Access Control](#4-roles-and-access-control)
5. [Supported Tokens](#5-supported-tokens)
6. [Pool Vault and Internal Ledger](#6-pool-vault-and-internal-ledger)
7. [Invoice System](#7-invoice-system)
8. [Payment Flows](#8-payment-flows)
   - [Prepaid Flow](#81-prepaid-flow)
   - [Postpaid Flow](#82-postpaid-flow)
   - [Recurring Flow](#83-recurring-flow)
9. [Escrow System](#9-escrow-system)
10. [Dispute Resolution](#10-dispute-resolution)
11. [Fee System](#11-fee-system)
12. [Subscription System](#12-subscription-system)
13. [Function Reference](#13-function-reference)
14. [Events Reference](#14-events-reference)
15. [Custom Errors Reference](#15-custom-errors-reference)
16. [Data Structures](#16-data-structures)
17. [Deployment Guide](#17-deployment-guide)
18. [Post-Deployment Configuration](#18-post-deployment-configuration)
19. [Security Model](#19-security-model)
20. [Gas Optimization](#20-gas-optimization)
21. [Integration Guide](#21-integration-guide)
22. [Emergency Procedures](#22-emergency-procedures)
23. [Upgrade Path](#23-upgrade-path)
24. [Changelog](#24-changelog)

---

## 1. Project Overview

CryptoPaymentPlatform is a crypto payment infrastructure layer built for the Arbitrum network. It allows merchants to raise invoices and receive payments from customers with the following design goals:

- **Gas efficiency** — internal transfers between users cost 5,000–10,000 gas instead of ~65,000 gas for a normal token transfer, because no tokens physically move between wallets during payment. The contract maintains an internal ledger and only updates numbers in a database-like table.
- **Single custody point** — all funds from all users sit inside one contract. There are no per-user wallet deployments or proxy contracts.
- **Complete payment lifecycle** — supports prepaid (escrow-backed), postpaid (instant settle), and recurring (pull-payment) invoice models in one contract.
- **Built-in dispute resolution** — admin and employees can adjudicate disputes and direct escrowed funds without requiring external arbitration.
- **Flexible fee model** — percentage-based or per-token flat fees, configurable globally or per merchant.

**Contract version:** `1.2.0`
**Solidity version:** `^0.8.20`
**Target network:** Arbitrum One / Arbitrum Nova

---

## 2. Key Concepts (Plain English)

> If you are already familiar with smart contracts and Solidity, skip to Section 3.

### What is a smart contract?

Think of it as a backend API and database combined — except it runs on a public blockchain instead of a server you own. Once deployed, the rules it enforces cannot be changed by anyone (including the deployer), and every transaction is permanently recorded on-chain.

### What is the Arbitrum network?

Arbitrum is a Layer 2 blockchain that runs on top of Ethereum. It processes transactions faster and at a fraction of the cost compared to Ethereum mainnet, making it practical for payment applications.

### What is a token?

Tokens are digital currencies that run on Ethereum/Arbitrum. This contract supports:
- **ETH** — the native currency of Ethereum (like USD in traditional finance)
- **USDT** — Tether, a stablecoin pegged to the US dollar
- **USDC** — USD Coin, another dollar stablecoin

All token amounts in the contract are integers in the token's smallest unit:
- ETH: amounts are in **wei** (1 ETH = 1,000,000,000,000,000,000 wei)
- USDT/USDC: amounts are in **6-decimal units** (1 USDT = 1,000,000)

### What is an internal ledger (pool vault)?

Instead of moving tokens between wallets for every payment, this contract keeps an internal accounting table — similar to a bank's internal database. When you "deposit", real tokens move into the contract once. After that, all payments are just number updates in that table. When you "withdraw", real tokens leave the contract to your wallet.

This is much cheaper (gas-efficient) than sending tokens back and forth for every transaction.

### What is escrow?

Escrow is a holding mechanism where funds are locked in a neutral place until a condition is met. In this contract, when a payer pays a prepaid invoice, the money is locked in the contract and cannot be accessed by either party until the merchant marks the job complete (or an admin resolves a dispute).

Think of it like a payment held in a third-party account until both sides confirm the transaction is done.

### What is gas?

Gas is the fee paid to process a transaction on the blockchain. On Arbitrum, gas fees are very small (usually fractions of a cent). Every function call that changes state costs gas, paid by the person calling the function.

### What is a wallet address?

Every participant (admin, merchant, payer) is identified by their wallet address — a 42-character hex string like `0xAb5801a7D398351b8bE11C439e05C5B3259aeC9B`. This is the blockchain equivalent of a user ID or email address.

### What does "on-chain" mean?

"On-chain" means the data or logic is stored/executed on the blockchain and is publicly readable, permanently recorded, and tamper-proof. Every invoice, payment, and dispute resolution in this contract is on-chain.

---

## 3. Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   CryptoPaymentPlatform                     │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               Pool Vault / Ledger                   │   │
│  │  _ledger[user][token] → uint256 balance             │   │
│  │                                                     │   │
│  │  Payer A:    USDT 500,  ETH 0.2                    │   │
│  │  Merchant B: USDT 300,  USDC 100                   │   │
│  │  Admin:      USDT 50   ← accumulated fees           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │   Invoice    │  │    Escrow    │  │   Recurring      │  │
│  │   Storage    │  │   Records    │  │   Approvals      │  │
│  │  _invoices   │  │   _escrow   │  │  _recurring      │  │
│  │  [invoiceId] │  │  [invoiceId] │  │  Approvals       │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │              Fee Configuration                     │    │
│  │  defaultFeeConfig + defaultFlatFeePerToken         │    │
│  │  _userFeeConfig   + _userFlatFeePerToken           │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
         ▲ deposit / withdraw (real token transfers)
         ▼
   User Wallets / External
```

**Key principle:** Real ERC-20 or ETH transfers happen only on deposit and withdrawal functions. Every payment, fee deduction, subscription charge, and escrow release is a pure ledger arithmetic operation — like updating rows in a database. No external token calls occur during payment, which eliminates reentrancy risk on payment paths and keeps gas costs low.

---

## 4. Roles and Access Control

> Think of roles like permission levels in a web application — Admin is a superuser, Employee is a moderator, Merchant is a verified seller account, and Payer is any regular user.

The contract uses OpenZeppelin `Ownable` for admin ownership and a custom `isEmployee` mapping for employee delegation.

### Admin (Owner)

The wallet that deploys the contract is automatically the admin. There can be only one admin at a time.

Exclusive admin capabilities:
- Transfer ownership to a new admin (`transferOwnership`)
- Add and remove employees (`addEmployee`, `removeEmployee`)
- Register merchants (`registerMerchant`)
- Pause and unpause the contract (`pause`, `unpause`)
- Configure global and per-user fees (`setDefaultFee`, `setDefaultFlatFee`, `setUserFee`, `setUserFlatFee`)
- Configure subscription settings (`setSubscriptionConfig`)
- Whitelist and delist tokens (`addSupportedToken`, `removeSupportedToken`)
- Set maximum open invoice cap (`setMaxOpenInvoices`)
- Execute emergency withdrawal (`emergencyWithdrawAll`)

### Employee

Employees are wallets granted the employee role by the admin. Multiple employees can be active simultaneously. Useful for a support team that handles disputes without needing full admin access.

Employee capabilities (shared with admin):
- Resolve disputes (`resolveDispute`)
- Force-release or force-refund escrow (`adminReleaseToMerchant`, `adminRefundToPayer`)
- Set and remove per-user fee overrides (`setUserFee`, `setUserFlatFee`, `removeUserFee`)
- Batch cancel invoices (`batchCancelInvoices`)

### Merchant

Any wallet registered by the admin via `registerMerchant`. Merchants must have an active subscription (if the subscription system is enabled) to create invoices.

Merchant capabilities:
- Create invoices (`createInvoice`)
- Cancel their own PENDING invoices (`cancelInvoice`)
- Mark prepaid invoices as complete (`markComplete`)
- Trigger recurring payment cycles (`triggerRecurring`)
- Pay their subscription (`paySubscription`)
- Deposit and withdraw funds (like any user)

### Payer

Any wallet address — no registration required. The merchant specifies the payer's wallet address when creating the invoice.

Payer capabilities:
- Pay invoices (`payPrepaidInvoice`, `payPostpaidInvoice`)
- Reject pending invoices before paying (`rejectInvoice`)
- Raise disputes on paid prepaid invoices (`raiseDispute`)
- Grant and revoke recurring payment approvals (`approveRecurring`, `revokeRecurring`)
- Deposit and withdraw funds

### Access Control Matrix

| Action | Admin | Employee | Merchant | Payer |
|--------|-------|----------|----------|-------|
| Register merchant | ✅ | ❌ | ❌ | ❌ |
| Add / remove employee | ✅ | ❌ | ❌ | ❌ |
| Pause contract | ✅ | ❌ | ❌ | ❌ |
| Create invoice | ❌ | ❌ | ✅ | ❌ |
| Pay invoice | ❌ | ❌ | ❌ | ✅ |
| Mark complete | ❌ | ❌ | ✅ | ❌ |
| Raise dispute | ❌ | ❌ | ❌ | ✅ |
| Resolve dispute | ✅ | ✅ | ❌ | ❌ |
| Set global fee | ✅ | ❌ | ❌ | ❌ |
| Set user fee | ✅ | ✅ | ❌ | ❌ |
| Batch cancel | ✅ | ✅ | ❌ | ❌ |
| Emergency withdraw | ✅ | ❌ | ❌ | ❌ |
| Deposit / withdraw | ✅ | ✅ | ✅ | ✅ |

---

## 5. Supported Tokens

> A "supported token" is a currency the platform accepts for payments. Only the admin can add or remove tokens from this list.

At deployment, three tokens are whitelisted automatically:

| Token | Arbitrum One Address | Decimals |
|-------|---------------------|----------|
| Native ETH | `address(0)` (internal sentinel) | 18 |
| USDT | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | 6 |
| USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 |

`address(0)` is used as the internal placeholder for native ETH throughout the ledger and invoice system. This is a convention only visible inside the contract — no actual zero-address token exists.

### Adding new tokens

```solidity
// Admin adds WETH (18 decimals) to the platform
platform.addSupportedToken(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, 18);
```

The `decimals` parameter is stored in `tokenDecimals[token]` and returned by `getTokenInfo(token)`. The contract does not use decimals in its own math — flat fees are stored in native token units, eliminating any conversion requirement — but the value is exposed for frontends and SDKs so they can format amounts correctly without an extra network call to the token contract.

### Removing tokens

Removing a token from the whitelist blocks new deposits, new invoices, and new recurring approvals denominated in that token. **Importantly, existing ledger balances are not affected** — users can still call `withdrawToken` to recover funds from a delisted token. ETH (`address(0)`) can never be delisted.

---

## 6. Pool Vault and Internal Ledger

> Think of this like a bank account system. Users deposit money into the bank (this contract). The bank keeps an internal ledger of who owns what. When users pay each other, the bank just updates its ledger — no physical money moves between branches. When a user wants their money back, the bank sends a real transfer to their wallet.

### The ledger data structure

```solidity
mapping(address => mapping(address => uint256)) private _ledger;
// _ledger[userWallet][tokenAddress] = balance in token base units
```

In plain terms: for every wallet address and every token, the contract stores a number representing that user's balance. This is like a two-column database table: `(user, token) → balance`.

### Depositing funds

**ETH (the native currency):**
```solidity
// Option 1: call the deposit function
platform.depositETH{value: 1 ether}();

// Option 2: send ETH directly to the contract address
// The receive() function handles it automatically (blocked while contract is paused)
```

**ERC-20 tokens (USDT, USDC, etc.):**
```solidity
// Step 1: allow the contract to move tokens from your wallet
IERC20(usdt).approve(address(platform), 100_000_000); // approve 100 USDT

// Step 2: deposit — tokens move from your wallet into the contract
platform.depositToken(usdt, 100_000_000);
```

The contract credits exactly the amount it receives, not the amount requested. This handles fee-on-transfer tokens correctly — the credited balance equals what actually arrived.

### Withdrawing funds

```solidity
// Withdraw a specific amount of USDT to your wallet
platform.withdrawToken(usdt, 50_000_000); // 50 USDT

// Withdraw a specific amount of ETH to your wallet
platform.withdrawETH(0.5 ether);

// Sweep all balances for multiple tokens in one call
address[] memory tokens = new address[](3);
tokens[0] = address(0); // ETH
tokens[1] = usdt;
tokens[2] = usdc;
platform.withdrawAllTokens(tokens);
```

> **Note on delisted tokens:** `withdrawToken` intentionally does NOT check whether a token is currently whitelisted. If admin removes a token from the supported list, existing holders can still withdraw their balance. The whitelist only controls whether new deposits and invoices can be created for that token.

### Checking balances

```solidity
// Check a merchant's USDT balance inside the contract
uint256 bal = platform.balanceOf(merchantAddress, usdtAddress);

// Check your own ETH balance inside the contract
uint256 ethBal = platform.balanceOf(msg.sender, address(0));
```

---

## 7. Invoice System

> An invoice in this contract works similarly to a regular business invoice — a merchant requests payment from a specific customer for a specific amount. The difference is that everything is recorded on-chain and payment happens inside the contract's ledger, not through a bank transfer.

### Creating an invoice

Only registered merchants with valid subscriptions (if enabled) can create invoices. A merchant cannot invoice themselves.

```solidity
uint256 invoiceId = platform.createInvoice(
    payerAddress,              // wallet address of the customer who must pay
    usdtAddress,               // which token to pay in
    500_000_000,               // 500 USDT (in 6-decimal units)
    block.timestamp + 7 days,  // payment deadline (UNIX timestamp)
    "Logo design for Acme Co", // description visible on-chain
    PaymentType.PREPAID,       // PREPAID (escrow) or POSTPAID (instant settle)
    false,                     // not a recurring invoice
    0,                         // recurring interval in seconds (0 = not recurring)
    0                          // max billing cycles (0 = not recurring)
);
```

For a recurring invoice (e.g. a monthly retainer):

```solidity
uint256 invoiceId = platform.createInvoice(
    payerAddress,
    usdtAddress,
    100_000_000,               // 100 USDT per billing cycle
    block.timestamp + 365 days,// overall contract expiry date
    "Monthly retainer",
    PaymentType.POSTPAID,
    true,                      // isRecurring = true
    30 days,                   // bill every 30 days
    12                         // bill a maximum of 12 times (1 year)
);
```

### Invoice lifecycle states

Every invoice moves through states like a state machine. Here is the full flow:

```
                  ┌──────────────────────────────┐
                  │           PENDING             │ ← created here
                  └──────────────────────────────┘
                    │           │          │
          payPrepaid │  payPostpaid│  triggerRecurring (1st cycle)
                    ▼           ▼          ▼
                  PAID      COMPLETED    ACTIVE ──► (more cycles)
                    │                      │
          markComplete │     final cycle   │
          or dispute   │                   ▼
                    ▼                 COMPLETED
                DISPUTED
                    │
           resolveDispute
                    ▼
                COMPLETED

   Any PENDING or ACTIVE invoice → CANCELLED
   (via cancelInvoice / rejectInvoice / batchCancelInvoices)
```

| Status | What it means |
|--------|--------------|
| `PENDING` | Invoice created, waiting for payment or first recurring cycle |
| `ACTIVE` | Recurring invoice: at least one cycle paid, more cycles remaining |
| `PAID` | Payer has paid a prepaid invoice; money is locked in escrow |
| `COMPLETED` | Invoice fully settled — job done, all cycles done, or dispute resolved |
| `CANCELLED` | Invoice voided by merchant, payer, admin, or emergency shutdown |
| `DISPUTED` | Payer opened a dispute; escrow is frozen, nobody can access the funds |

### Invoice IDs

Invoice IDs are auto-incremented integers starting from 1. ID 0 is reserved as "not found". The total number of invoices ever created is readable via `totalInvoices()`.

### Querying invoices

```solidity
// Get full details of an invoice
Invoice memory inv = platform.getInvoice(invoiceId);

// Get all invoice IDs ever created by a merchant
uint256[] memory ids = platform.getMerchantInvoices(merchantAddress);

// Get all invoice IDs assigned to a payer
uint256[] memory ids = platform.getPayerInvoices(payerAddress);

// Get how many non-terminal invoices a merchant currently has open
uint256 open = platform.getOpenInvoiceCount(merchantAddress);
```

### Open invoice cap

The admin can limit how many non-terminal invoices (PENDING + ACTIVE + PAID + DISPUTED) a merchant may hold at the same time. This prevents spam:

```solidity
platform.setMaxOpenInvoices(50); // 50 maximum open invoices per merchant; 0 = unlimited
```

When this limit is changed, a `MaxOpenInvoicesUpdated` event is emitted so the backend can track the configuration change.

---

## 8. Payment Flows

> There are three ways to pay: Prepaid (payer deposits into escrow first), Postpaid (merchant works first, payer pays on delivery), and Recurring (standing authorisation for automatic billing). Choose the model that fits the merchant-customer relationship.

### 8.1 Prepaid Flow

The payer funds an escrow before the merchant starts work. This protects the payer — funds cannot reach the merchant until the job is declared complete.

**Step 1 — Merchant creates invoice (status: PENDING)**
```solidity
uint256 id = platform.createInvoice(
    payerAddress, usdtAddress, 200_000_000, dueDate,
    "Website development", PaymentType.PREPAID, false, 0, 0
);
```

**Step 2 — Payer funds escrow (status: PENDING → PAID)**
```solidity
// The deadline parameter stops a stale transaction from being processed days later
uint256 deadline = block.timestamp + 1 hours;
platform.payPrepaidInvoice(id, deadline);
```

At this point `200 USDT` is deducted from the payer's internal ledger and locked in escrow. No fee is taken yet.

**Step 3 — Merchant completes work (status: PAID → COMPLETED)**
```solidity
platform.markComplete(id);
```

The contract deducts the platform fee from the escrowed 200 USDT and credits the net amount to the merchant's ledger. The fee goes to the admin's ledger.

**Step 4 — Merchant withdraws their earnings (optional)**
```solidity
platform.withdrawToken(usdt, platform.balanceOf(merchantAddress, usdt));
```

---

### 8.2 Postpaid Flow

The merchant completes work first, then raises the invoice. The payer pays on receipt and funds settle immediately with no escrow.

**Step 1 — Merchant creates invoice after completing work (status: PENDING)**
```solidity
uint256 id = platform.createInvoice(
    payerAddress, usdcAddress, 150_000_000, dueDate,
    "SEO audit report", PaymentType.POSTPAID, false, 0, 0
);
```

**Step 2 — Payer reviews and pays (status: PENDING → COMPLETED)**
```solidity
platform.payPostpaidInvoice(id, block.timestamp + 2 hours);
```

In one atomic operation the contract:
1. Deducts the full amount from the payer's ledger
2. Calculates the platform fee
3. Credits the net amount to the merchant's ledger
4. Credits the fee to the admin's ledger
5. Marks the invoice COMPLETED

---

### 8.3 Recurring Flow

A payer grants a standing pull-payment authorisation (like setting up a direct debit). The merchant triggers each billing cycle independently.

**Step 1 — Merchant creates recurring invoice (status: PENDING)**
```solidity
uint256 id = platform.createInvoice(
    payerAddress, usdtAddress,
    50_000_000,                 // 50 USDT per billing cycle
    block.timestamp + 365 days, // overall contract expiry
    "Monthly SaaS subscription",
    PaymentType.POSTPAID,
    true,                       // isRecurring = true
    30 days,                    // bill every 30 days
    12                          // maximum 12 cycles (1 year total)
);
```

**Step 2 — Payer grants approval (like authorising a direct debit)**
```solidity
platform.approveRecurring(
    merchantAddress,
    usdtAddress,
    50_000_000,    // maximum amount per cycle
    600_000_000    // total budget cap across all cycles (0 = no limit)
);
```

**Step 3 — Merchant triggers each billing cycle**
```solidity
// Call once per billing period; the contract rejects calls that are too early
platform.triggerRecurring(id);
```

Each call automatically:
- Verifies the payer's approval is still active and limits are not exceeded
- Verifies the billing date has arrived (`block.timestamp >= nextDueDate`)
- Verifies the overall invoice has not expired
- Deducts the cycle amount from the payer's ledger
- Credits net (minus fee) to the merchant's ledger
- Advances the next billing date forward by the recurring interval
- Sets status to `ACTIVE` (if cycles remain) or `COMPLETED` (if all cycles done)

**Step 4 — Payer revokes approval (optional)**
```solidity
platform.revokeRecurring(merchantAddress, usdtAddress);
// Future triggerRecurring calls will fail with RecurringNotApproved
```

> **Important:** Revoking approval stops future cycles but does not cancel the invoice itself. Only admin or employee can cancel an `ACTIVE` recurring invoice. If a payer wants to stop recurring billing entirely, they should revoke the approval AND ask admin to cancel the invoice.

**Checking approval status:**
```solidity
(bool active, uint256 maxPerCycle, uint256 totalLimit,
 uint256 totalSpent, uint256 remaining) =
    platform.getRecurringApproval(payerAddress, merchantAddress, usdtAddress);
```

**Listing all merchants a payer has ever approved:**
```solidity
address[] memory merchants = platform.getPayerApprovedMerchants(payerAddress);
// Note: may include revoked approvals — check getRecurringApproval for current active status
```

---

## 9. Escrow System

> Escrow in this contract works like a trusted middleman holding payment in a locked safe. The payer's money goes into the safe when they pay. The merchant can only receive it once they declare the job complete. If there is a dispute, only an admin can open the safe and decide where the money goes.

Escrow applies only to PREPAID invoices. When `payPrepaidInvoice` is called, the full invoice amount is moved from the payer's ledger into a separate escrow record:

```solidity
struct EscrowRecord {
    address token;
    uint256 amount;
    bool    frozen;   // true when a dispute is open — nobody can touch the funds
    bool    released; // true once funds have been settled — prevents double-release
}
```

### Escrow release paths

| Trigger | Function | Who can call | Outcome |
|---------|----------|-------------|---------|
| Normal completion | `markComplete` | Merchant | Net → merchant ledger; fee → admin ledger |
| Dispute: merchant wins | `resolveDispute(id, true, reason)` | Admin / Employee | Net → merchant ledger; fee → admin ledger |
| Dispute: payer wins | `resolveDispute(id, false, reason)` | Admin / Employee | Full amount → payer ledger (no fee deducted) |
| Admin force-release | `adminReleaseToMerchant(id)` | Admin / Employee | Net → merchant ledger; fee → admin ledger |
| Admin force-refund | `adminRefundToPayer(id)` | Admin / Employee | Full amount → payer ledger (no fee deducted) |
| Emergency shutdown | `emergencyWithdrawAll(...)` | Admin (paused only) | Full amount → payer's wallet directly |

> **Note:** `adminReleaseToMerchant` and `adminRefundToPayer` only work on invoices in `PAID` or `DISPUTED` status. Calling them on any other status (e.g. a PENDING invoice with no escrow) will revert with `InvalidInvoiceStatus`. This prevents admin from accidentally completing unpaid invoices.

### Inspecting escrow

```solidity
(address token, uint256 amount, bool frozen, bool released) =
    platform.getEscrow(invoiceId);
```

---

## 10. Dispute Resolution

> Disputes work like a chargeback system. If a payer is unhappy after paying a prepaid invoice, they can raise a dispute which freezes the funds. An admin or employee then investigates and decides who gets the money.

Only payers can raise disputes, and only on PREPAID invoices in PAID status (i.e. after payment but before the merchant marks it complete).

### Raising a dispute

```solidity
platform.raiseDispute(invoiceId, "Merchant delivered wrong files, not as agreed.");
```

What happens immediately:
- The escrow is frozen — neither the merchant nor the payer can access the funds
- Invoice status changes to `DISPUTED`
- Events emitted: `DisputeRaised`, `FundsHeld`

### Resolving a dispute

An admin or employee investigates the situation off-chain (checks deliverables, messages, evidence) and then calls:

```solidity
// Decision: merchant wins — release net amount to merchant
platform.resolveDispute(invoiceId, true, "Deliverables verified against brief.");

// Decision: payer wins — full refund to payer with no fee charged
platform.resolveDispute(invoiceId, false, "Merchant missed deadline per contract.");
```

What happens:
- Escrow is unfrozen
- Funds are directed to the winner's internal ledger
- Invoice status changes to `COMPLETED`
- Events emitted: `DisputeResolved`, then either `FundsReleased` (merchant wins) or `FundsRefunded` (payer wins)

### Important rules

- Frozen escrow cannot be touched by anyone except through the dispute resolution functions
- Refunds always return the full invoice amount with zero fee deducted
- Releases always deduct the platform fee before crediting the merchant
- Once resolved, the invoice is `COMPLETED` and cannot be re-disputed
- There is currently no automatic timeout on disputes — admin must resolve them manually

### Admin force-release and force-refund

These skip the formal dispute flow and are useful for off-chain settled cases:

```solidity
// Admin decides to release to merchant without going through raiseDispute first
platform.adminReleaseToMerchant(invoiceId);

// Admin decides to refund payer without going through raiseDispute first
platform.adminRefundToPayer(invoiceId);
```

Both functions require the invoice to be in `PAID` or `DISPUTED` status. They cannot be called on invoices that have not been paid.

---

## 11. Fee System

> The fee system is like a commission structure. When a payment settles, the platform takes a cut (either a percentage of the transaction or a fixed amount), and the rest goes to the merchant. Fees accumulate in the admin's internal ledger and can be withdrawn at any time.

### Fee modes

**PERCENTAGE mode (default at deployment)**

A single percentage rate applied uniformly across all tokens. The rate is expressed in basis points where 100 bps = 1%.

```solidity
// Set global fee to 2.5%
platform.setDefaultFee(FeeType.PERCENTAGE, 250);
```

Fee calculation: `fee = (amount × bps) / 10,000`

Examples:
- 2.5% of 100 USDT = 2.50 USDT fee, merchant receives 97.50 USDT
- 2.5% of 1 ETH = 0.025 ETH fee, merchant receives 0.975 ETH

**FLAT mode**

A fixed amount per token, stored in that token's own base units. Each token has its own flat fee amount, so there is no decimal conversion problem — the USDT fee is stored in USDT units, the ETH fee is stored in wei.

```solidity
// Switch global to FLAT mode and configure each token separately
platform.setDefaultFlatFee(usdtAddress, 1_000_000);          // 1 USDT flat fee
platform.setDefaultFlatFee(usdcAddress, 1_000_000);          // 1 USDC flat fee
platform.setDefaultFlatFee(address(0), 500_000_000_000_000); // 0.0005 ETH flat fee
```

### Per-merchant fee overrides

Different merchants can have different fee rates:

```solidity
// Premium merchant: 1% instead of the default 2.5%
platform.setUserFee(premiumMerchant, FeeType.PERCENTAGE, 100);

// Enterprise merchant: fixed flat fee of 0.50 USDT per invoice regardless of size
platform.setUserFlatFee(enterpriseMerchant, usdtAddress, 500_000);
platform.setUserFlatFee(enterpriseMerchant, usdcAddress, 500_000);
platform.setUserFlatFee(enterpriseMerchant, address(0), 250_000_000_000_000);

// Remove merchant override — revert to global default
platform.removeUserFee(merchantAddress);
```

### Fee resolution order

When calculating the fee for a payment, the contract checks:

```
1. Does this merchant have a custom fee override?
   YES → PERCENTAGE mode: use their custom basis points
         FLAT mode: use their custom per-token flat amount
   NO  → Use the global platform default
         PERCENTAGE mode: use the global basis points
         FLAT mode: use the global per-token flat amount
```

### Previewing fees before paying

Your frontend can show users what the fee split will be before any transaction is submitted:

```solidity
(uint256 fee, uint256 net) = platform.previewFee(
    merchantAddress,
    500_000_000, // 500 USDT
    usdtAddress
);
// fee = platform cut in USDT base units
// net = what merchant receives in USDT base units
```

### Collecting accumulated fees

All fees accumulate in the admin's internal ledger. The admin withdraws them the same way any user withdraws:

```solidity
uint256 accumulatedFees = platform.balanceOf(adminAddress, usdtAddress);
platform.withdrawToken(usdtAddress, accumulatedFees);
```

### Querying effective fee for a merchant

```solidity
// Get the fee mode and value currently applied to a merchant
(FeeType mode, uint256 val, bool isOverride) = platform.getEffectiveFee(merchantAddress);

// Get the flat fee for a specific token (returns 0 if mode is PERCENTAGE)
uint256 flatAmount = platform.getEffectiveFlatFee(merchantAddress, usdtAddress);
```

---

## 12. Subscription System

> The subscription system is like a SaaS licence for merchants. Admin can require merchants to pay a monthly fee to keep their invoice-creation access active. If a merchant does not pay their subscription, they cannot create new invoices.

### Configuration

```solidity
// Require merchants to pay 10 USDC per month
platform.setSubscriptionConfig(
    usdcAddress,   // token used for subscription payment
    10_000_000,    // 10 USDC (6-decimal units)
    30 days        // how long the subscription lasts after payment
);

// Disable subscriptions entirely (free to use)
platform.setSubscriptionConfig(usdcAddress, 0, 30 days);
```

> **Validation:** If the fee is greater than zero, the token must be on the supported whitelist — the contract rejects configuration that would make subscription payment impossible.

### Merchant paying their subscription

The subscription fee is deducted from the merchant's internal ledger balance and credited to the admin's ledger. No real token transfer between wallets occurs.

```solidity
// Merchant must have sufficient USDC in their internal ledger first
platform.paySubscription();
```

After calling, the subscription is active for `subscriptionDuration` seconds from the current time. Paying early resets the expiry from now, not from the old expiry.

### Checking subscription status

```solidity
bool valid = platform.isSubscriptionValid(merchantAddress);
// createInvoice() also checks this internally and reverts with SubscriptionExpired if invalid
```

### Free platform

If `subscriptionFee` is 0, any registered merchant can call `paySubscription()` to activate themselves at no cost. If subscriptions are not needed at all, leave `subscriptionFee` at 0 and the check in `createInvoice` is skipped entirely.

---

## 13. Function Reference

> This section is the technical API reference. Each function entry lists its visibility (who can call it from outside the contract), which security modifiers it applies, and what it does.

**Glossary of modifiers:**
- `nonReentrant` — prevents the function from being called again while it is still executing (reentrancy protection)
- `whenNotPaused` — reverts if the contract is paused by admin
- `onlyAdmin` — only the contract owner can call
- `onlyAdminOrEmployee` — owner or any registered employee can call
- `onlySupportedToken(token)` — reverts if the token is not whitelisted
- `invoiceExists(invoiceId)` — reverts if the invoice ID does not exist

---

### Deposit functions

#### `depositETH()`
```
Visibility: external payable
Modifiers:  nonReentrant, whenNotPaused
```
Deposits `msg.value` ETH into the caller's internal ledger. Reverts if `msg.value == 0`.

---

#### `depositToken(address token, uint256 amount)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlySupportedToken(token)
Parameters:
  token  — ERC-20 contract address (must be whitelisted; not address(0) — use depositETH for ETH)
  amount — amount to deposit in token base units
```
Pulls tokens from caller's wallet via `safeTransferFrom`. Credits exactly the amount received (handles fee-on-transfer tokens via before/after balance diff). Reverts if `amount == 0` or token is `address(0)`.

---

### Withdrawal functions

#### `withdrawETH(uint256 amount)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused
Parameters:
  amount — ETH amount in wei to send to caller's wallet
```
Checks ledger balance, deducts (effect first), then sends ETH (interaction last — follows CEI pattern). Reverts if balance is insufficient or ETH transfer fails.

---

#### `withdrawToken(address token, uint256 amount)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused
Parameters:
  token  — ERC-20 contract address (not address(0))
  amount — amount in token base units
```
Deducts from the caller's internal ledger, then calls `safeTransfer` to send tokens to the caller's wallet. **Does not require the token to be currently whitelisted** — users can always withdraw balances in delisted tokens. Reverts if balance is insufficient.

---

#### `withdrawAllTokens(address[] calldata tokens)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused
Parameters:
  tokens — array of token addresses to sweep (include address(0) for ETH)
```
Iterates the provided list and withdraws the full balance for each token with a non-zero balance. Silently skips tokens with zero balance. If an ETH send fails, the balance is restored for that token and the loop continues to sweep remaining ERC-20 tokens successfully.

---

### User management functions

#### `registerMerchant(address merchant)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Grants merchant role to the address. Emits `UserRegistered`.

---

#### `addEmployee(address employee)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Grants employee role. Updates both the `isEmployee` mapping and `_userConfig` struct. Emits `EmployeeAdded`, `UserRoleUpdated`.

---

#### `removeEmployee(address employee)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Revokes employee role. Emits `EmployeeRemoved`, `UserRoleUpdated`.

---

### Subscription functions

#### `paySubscription()`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused
Caller:     merchant only
```
Deducts `subscriptionFee` in `subscriptionToken` from caller's ledger and credits admin's ledger. Marks subscription active for `subscriptionDuration`. Emits `SubscriptionPaid`, `InternalTransfer`.

---

#### `isSubscriptionValid(address merchant) → bool`
```
Visibility: public view
```
Returns true if `subscriptionActive == true` and `subscriptionExpiry >= block.timestamp`.

---

### Invoice management functions

#### `createInvoice(address payer, address token, uint256 amount, uint256 dueDate, string description, PaymentType paymentType, bool isRecurring, uint256 recurringInterval, uint256 maxCycles) → uint256 invoiceId`
```
Visibility: external
Modifiers:  whenNotPaused, onlySupportedToken(token)
Caller:     merchant only (registered, subscription active)
```
Creates a new invoice. Validates all inputs (including that payer is not the merchant themselves). Assigns a unique ID, stores the invoice, updates merchant and payer index arrays, increments open invoice counter. Returns the new invoice ID. Emits `InvoiceCreated`.

---

#### `cancelInvoice(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  invoiceExists(invoiceId)
Caller:     merchant (PENDING status only) | admin / employee (PENDING or ACTIVE)
```
Sets status to `CANCELLED`. Decrements merchant's open invoice count. Emits `InvoiceCancelled`.

> **Why can't the merchant cancel an ACTIVE invoice?** ACTIVE means recurring cycles are in progress. Allowing the merchant to cancel mid-stream would let them stop billing after receiving payment for early cycles while leaving the invoice in a non-terminal state. Only admin or employee can cancel ACTIVE invoices to prevent this abuse.

---

#### `rejectInvoice(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  invoiceExists(invoiceId)
Caller:     payer only, PENDING status only
```
Payer-side cancellation of an invoice they have not yet paid. Sets status to `CANCELLED`. Decrements open invoice count. Emits `InvoiceCancelled`.

---

### Payment functions

#### `payPrepaidInvoice(uint256 invoiceId, uint256 deadline)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only
```
Deducts invoice amount from payer's ledger and locks it in `_escrow[invoiceId]`. Sets status to `PAID`. Increments payer nonce. Reverts if: deadline passed, wrong payment type, wrong invoice status, past due date, or insufficient balance. Emits `FundsLocked`, `InvoicePaid`.

---

#### `markComplete(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     invoice merchant only, PAID status only
```
Releases escrowed funds to merchant minus platform fee. Sets status to `COMPLETED`. Decrements open invoice count. Reverts if escrow is frozen (dispute open) or already released. Emits `FeeDeducted`, `FundsReleased`, `InternalTransfer`, `InvoiceMarkedComplete`.

---

#### `payPostpaidInvoice(uint256 invoiceId, uint256 deadline)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only
```
Atomic single-step settlement: deducts gross amount from payer, credits net to merchant, credits fee to admin. Sets status to `COMPLETED`. Decrements open invoice count. Increments payer nonce. Emits `FeeDeducted`, `InternalTransfer`, `InvoicePaid`, `InvoiceMarkedComplete`.

---

### Recurring payment functions

#### `approveRecurring(address merchant, address token, uint256 maxPerCycle, uint256 totalLimit)`
```
Visibility: external
Modifiers:  whenNotPaused, onlySupportedToken(token)
Caller:     payer
```
Creates or overwrites a recurring pull-payment authorisation. If `totalLimit == 0`, spending is unlimited. Records the merchant in the payer's approved-merchants list (deduplicated — each merchant appears only once per payer). Overwrites the full approval including resetting `totalSpent` to 0.

---

#### `revokeRecurring(address merchant, address token)`
```
Visibility: external
Caller:     payer
```
Sets `active = false` on the approval. Does not delete the record (spend history is preserved). Future `triggerRecurring` calls on affected invoices will revert with `RecurringNotApproved`.

---

#### `triggerRecurring(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     invoice merchant only
```
Executes one billing cycle. Performs 9 sequential validation checks (role, recurring flag, status, max cycles, timing, expiry, approval active, per-cycle limit, total limit). Settles payment from payer's ledger to merchant's ledger (minus fee). Sets status to `ACTIVE` (if cycles remain) or `COMPLETED` (if all done). Decrements open invoice count only on the final cycle. Emits `FeeDeducted`, `InternalTransfer`, `RecurringInvoiceTriggered`, and optionally `InvoiceMarkedComplete`.

---

### Dispute functions

#### `raiseDispute(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  whenNotPaused, invoiceExists
Caller:     payer only — PREPAID invoices in PAID status only
```
Freezes escrow. Sets status to `DISPUTED`. Emits `DisputeRaised`, `FundsHeld`.

---

#### `resolveDispute(uint256 invoiceId, bool releaseToMerchant, string reason)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
```
Unfreezes escrow. Directs funds to winner. Sets status to `COMPLETED`. Decrements open invoice count.
- `releaseToMerchant = true`: fee deducted, net credited to merchant. Emits `FeeDeducted`, `FundsReleased`.
- `releaseToMerchant = false`: full amount refunded to payer, no fee. Emits `FundsRefunded`.
- Always emits `DisputeResolved`.

---

#### `adminReleaseToMerchant(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
Requires:   invoice status must be PAID or DISPUTED
```
Force-releases escrow to merchant outside the formal dispute flow. Useful for off-chain resolved cases. Emits `FeeDeducted`, `FundsReleased`, `InternalTransfer`, `InvoiceMarkedComplete`.

---

#### `adminRefundToPayer(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
Requires:   invoice status must be PAID or DISPUTED
```
Force-refunds full escrow amount to payer. No fee deducted. Emits `FundsRefunded`.

---

### Fee management functions

#### `setDefaultFee(FeeType feeType, uint256 value)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  feeType — FeeType.PERCENTAGE or FeeType.FLAT
  value   — basis points for PERCENTAGE (max 10,000); ignored for FLAT
```
Sets global fee mode. For FLAT mode, also call `setDefaultFlatFee` per token to configure amounts. Emits `FeeConfigUpdated`.

---

#### `setDefaultFlatFee(address token, uint256 amount)`
```
Visibility: external
Modifiers:  onlyAdmin, onlySupportedToken(token)
Parameters:
  token  — token whose flat fee is being configured
  amount — fee in token's base units (e.g. 1_000_000 = 1 USDT; 5e14 ≈ 0.0005 ETH)
```
Sets global flat fee for a specific token. Also auto-switches the global fee mode to FLAT. Emits `FlatFeeUpdated`, `FeeConfigUpdated`.

---

#### `setUserFee(address user, FeeType feeType, uint256 value)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee
```
Sets a per-merchant fee override. Emits `FeeConfigUpdated`, `UserFeeTierUpdated`.

---

#### `setUserFlatFee(address user, address token, uint256 amount)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee, onlySupportedToken(token)
```
Sets a per-token flat fee for a specific merchant. Also marks that merchant's fee config as FLAT mode. Multiple calls for different tokens are additive — each token gets its own slot. Emits `FlatFeeUpdated`, `UserFeeTierUpdated`.

---

#### `removeUserFee(address user)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee
```
Deletes the merchant's fee override (reverts them to the global default). Flat fee entries remain in storage but are ignored while the override is unset. Emits `FeeConfigUpdated`.

---

#### `setSubscriptionConfig(address token, uint256 fee, uint256 duration)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  token    — token used for subscription payments (must be whitelisted if fee > 0)
  fee      — monthly fee in token base units (0 = free)
  duration — validity period in seconds
```
Reconfigures the merchant subscription system. Reverts if `fee > 0` and the token is not whitelisted.

---

### Admin control functions

#### `pause()` / `unpause()`
```
Visibility: external
Modifiers:  onlyAdmin
```
Pauses or unpauses all state-changing functions (deposits, withdrawals, payments, invoice creation, etc.). Direct ETH sends to the contract address are also blocked while paused. The emergency withdrawal function (`emergencyWithdrawAll`) remains available to admin while paused.

---

#### `addSupportedToken(address token, uint8 decimals)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  token    — ERC-20 contract address (not address(0))
  decimals — decimal precision of the token (e.g. 6 for USDT/USDC, 18 for WETH)
```
Whitelists a new token and stores its decimal count. `address(0)` is blocked — native ETH is pre-whitelisted in the constructor via a separate path. Emits `TokenAdded`.

---

#### `removeSupportedToken(address token)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Removes a token from the whitelist. `address(0)` (ETH) can never be removed. Existing balances in the delisted token are unaffected — users can still withdraw. Emits `TokenRemoved`.

---

#### `setMaxOpenInvoices(uint256 limit)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  limit — max concurrent non-terminal invoices per merchant (0 = unlimited)
```
Sets the open invoice cap. Emits `MaxOpenInvoicesUpdated`.

---

#### `batchCancelInvoices(uint256[] calldata invoiceIds, string calldata reason)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee
```
Cancels all `PENDING` and `ACTIVE` invoices in the provided array in a single transaction. Silently skips non-existent IDs and invoices in states that cannot be batch-cancelled (`PAID`, `DISPUTED`, `COMPLETED`, `CANCELLED`).

> **Why are PAID and DISPUTED invoices skipped in batch cancel?** Those invoices have real money locked in escrow. Batch-cancelling them would leave the escrow funds in limbo. Use `adminRefundToPayer` or `adminReleaseToMerchant` individually for each PAID or DISPUTED invoice that needs to be resolved.

Emits `InvoiceCancelled` for each successfully cancelled invoice.

---

#### `transferOwnership(address newOwner)`
```
Visibility: public
Modifiers:  onlyOwner
```
Transfers admin role to a new wallet. Overrides OpenZeppelin's implementation to also emit `AdminTransferred`.

---

### Emergency function

#### `emergencyWithdrawAll(address[] calldata users, address[] calldata tokens, uint256[] calldata escrowInvoiceIds)`
```
Visibility: external
Modifiers:  nonReentrant, onlyAdmin
Requires:   contract must be paused
```
Two-phase sweep that returns all funds to their rightful owners:

**Phase 1 — Ledger sweep:** For each `users[i]` × `tokens[j]` combination, sends the full ledger balance directly to the user's wallet. If an ETH send fails for a user, their balance is restored so admin can retry. ERC-20 failures bubble up via SafeERC20.

**Phase 2 — Escrow sweep:** For each invoice ID in `escrowInvoiceIds`, refunds the escrowed amount to the original payer's wallet and cancels the invoice. If an ETH send fails for a payer, the amount is credited to their internal ledger as a fallback so they can withdraw it once the contract is unpaused.

Safe to call in batches or multiple times — already-zero balances and already-released escrows are silently skipped.

---

### View / query functions

| Function | Returns | What it tells you |
|----------|---------|------------------|
| `getInvoice(id)` | `Invoice` | All fields of a specific invoice |
| `balanceOf(user, token)` | `uint256` | A user's internal ledger balance |
| `getMerchantInvoices(merchant)` | `uint256[]` | All invoice IDs created by a merchant |
| `getPayerInvoices(payer)` | `uint256[]` | All invoice IDs assigned to a payer |
| `getRecurringApproval(payer, merchant, token)` | 5-tuple | Approval status, limits, and spend so far |
| `getPayerApprovedMerchants(payer)` | `address[]` | All merchants ever approved by a payer |
| `getEscrow(invoiceId)` | 4-tuple | Escrow token, amount, frozen flag, released flag |
| `getEffectiveFee(merchant)` | 3-tuple | Active fee mode and value for a merchant |
| `getEffectiveFlatFee(merchant, token)` | `uint256` | Active flat fee for a merchant-token pair |
| `getTokenInfo(token)` | `(bool, uint8)` | Whether the token is whitelisted and its decimals |
| `getUserConfig(user)` | `UserConfig` | Role flags and subscription info for a wallet |
| `getOpenInvoiceCount(merchant)` | `uint256` | Current number of non-terminal invoices |
| `totalInvoices()` | `uint256` | Total invoices ever created (= last invoice ID) |
| `previewFee(merchant, amount, token)` | `(fee, net)` | Simulate a fee split before submitting a transaction |
| `isSubscriptionValid(merchant)` | `bool` | Whether a merchant's subscription is currently active |

---

## 14. Events Reference

> Events are the blockchain equivalent of server-side logs. Your backend or indexing service listens for these events to know when something happened on-chain. Every important action in the contract emits at least one event.

| Event | Parameters | Emitted when |
|-------|-----------|-------------|
| `UserRegistered` | `user, role` | Admin registers a merchant |
| `UserRoleUpdated` | `user, newRole` | Employee added or removed |
| `UserFeeTierUpdated` | `user, FeeConfig` | Per-user fee changed |
| `Deposit` | `user, token, amount` | Any deposit (function call or direct ETH send) |
| `Withdrawal` | `user, token, amount` | Any successful withdrawal |
| `TokenAdded` | `token, decimals` | Admin whitelists a new token |
| `TokenRemoved` | `token` | Admin removes a token from the whitelist |
| `MaxOpenInvoicesUpdated` | `newLimit` | Admin changes the open invoice cap |
| `InvoiceCreated` | `invoiceId, merchant, payer, amount, token, paymentType, isRecurring` | New invoice created |
| `InvoiceCancelled` | `invoiceId, reason` | Invoice cancelled or rejected |
| `InvoicePaid` | `invoiceId, payer, amount, timestamp` | Payer pays an invoice |
| `InvoiceMarkedComplete` | `invoiceId, merchant` | Invoice reaches COMPLETED status |
| `RecurringInvoiceTriggered` | `invoiceId, cycleNumber` | One recurring billing cycle executed |
| `FundsLocked` | `invoiceId, amount` | Escrow created when payer pays prepaid invoice |
| `FundsReleased` | `invoiceId, merchant, netAmount` | Escrow released to merchant |
| `FundsRefunded` | `invoiceId, payer, amount` | Escrow refunded to payer |
| `FundsHeld` | `invoiceId, reason` | Payer raises a dispute (escrow frozen) |
| `DisputeRaised` | `invoiceId, payer, reason` | Payer opens a dispute |
| `DisputeResolved` | `invoiceId, decision, resolver` | Admin resolves a dispute |
| `FeeDeducted` | `invoiceId, feeAmount, token` | Platform fee credited to admin |
| `FeeConfigUpdated` | `user, FeeConfig` | Global or per-user fee mode changed |
| `FlatFeeUpdated` | `user, token, amount` | Per-token flat fee amount set |
| `AdminTransferred` | `oldAdmin, newAdmin` | Contract ownership transferred |
| `EmployeeAdded` | `employee` | Employee role granted |
| `EmployeeRemoved` | `employee` | Employee role revoked |
| `SubscriptionPaid` | `merchant, expiry` | Merchant pays subscription |
| `InternalTransfer` | `from, to, token, amount` | Any ledger-to-ledger payment |

---

## 15. Custom Errors Reference

> Custom errors are more gas-efficient than error strings and give you precise, programmatic error handling. When a transaction reverts, decode the error to understand exactly what went wrong.

| Error | Parameters | What caused it |
|-------|-----------|---------------|
| `Unauthorized()` | — | Caller does not have the required role for this action |
| `TokenNotSupported(token)` | `address` | Token is not on the whitelist |
| `InsufficientBalance(user, token, required, available)` | addresses + uint | Internal ledger balance is too low for this operation |
| `InvoiceNotFound(invoiceId)` | `uint256` | No invoice exists for this ID |
| `InvalidInvoiceStatus(invoiceId, current)` | `uint256, InvoiceStatus` | The invoice is in the wrong state for this operation |
| `InvoiceDueDatePassed(invoiceId)` | `uint256` | The invoice's due date has already passed |
| `EscrowFrozen(invoiceId)` | `uint256` | A dispute is open — escrow is locked |
| `EscrowAlreadyReleased(invoiceId)` | `uint256` | Escrow was already settled (prevents double-release) |
| `RecurringNotApproved()` | — | Payer's recurring approval is inactive or does not exist |
| `RecurringLimitExceeded()` | — | This cycle would exceed the per-cycle or total budget limit |
| `MaxCyclesReached(invoiceId)` | `uint256` | All billing cycles for this invoice have been completed |
| `TooEarlyForCycle(invoiceId, nextDue)` | `uint256, uint256` | The next billing date has not arrived yet |
| `SubscriptionExpired(merchant)` | `address` | Merchant's subscription has lapsed |
| `InvalidAmount()` | — | Amount is zero, or recurring parameters are invalid |
| `InvalidFeeConfig()` | — | Basis points value exceeds 10,000 (would mean >100% fee) |
| `TransactionExpired()` | — | `block.timestamp > deadline` parameter |
| `ZeroAddress()` | — | A disallowed zero address was passed |
| `ContractMustBePaused()` | — | Emergency function called while contract is live |
| `MaxOpenInvoicesReached(merchant, limit)` | `address, uint256` | Merchant has hit the open invoice cap |
| `EnforcedPause()` | — | Function called while contract is paused (including direct ETH sends) |

---

## 16. Data Structures

> These are the on-chain data types used throughout the contract. Understanding them helps you correctly parse event data and API responses.

### Invoice struct

```solidity
struct Invoice {
    uint256       id;                // unique invoice ID (starts at 1)
    address       payer;             // customer wallet address
    address       merchant;          // seller wallet address
    address       token;             // payment token (address(0) = ETH)
    uint256       amount;            // gross amount in token base units
    uint256       dueDate;           // overall expiry as UNIX timestamp
    string        description;       // human-readable job description
    PaymentType   paymentType;       // PREPAID or POSTPAID
    InvoiceStatus status;            // current state in the lifecycle
    bool          isRecurring;       // true if this is a recurring invoice
    uint256       recurringInterval; // seconds between billing cycles (0 = not recurring)
    uint256       maxCycles;         // total billing cycles allowed (0 = not recurring)
    uint256       completedCycles;   // number of cycles successfully billed so far
    uint256       nextDueDate;       // UNIX timestamp when next cycle becomes eligible
    uint256       createdAt;         // UNIX timestamp when invoice was created
}
```

### UserConfig struct

```solidity
struct UserConfig {
    bool    isEmployee;          // true if this wallet has employee role
    bool    isMerchant;          // true if this wallet is a registered merchant
    bool    subscriptionActive;  // true if subscription was ever paid
    uint256 subscriptionExpiry;  // UNIX timestamp when subscription expires
}
```

### FeeConfig struct

```solidity
struct FeeConfig {
    FeeType feeType; // PERCENTAGE or FLAT
    uint256 value;   // basis points if PERCENTAGE; unused if FLAT
    bool    isSet;   // false = no override, use global default
}
```

### RecurringApproval struct

```solidity
struct RecurringApproval {
    uint256 maxAmount;  // maximum that can be deducted per single cycle
    uint256 totalLimit; // total budget cap across all cycles (0 = unlimited)
    uint256 totalSpent; // cumulative amount billed under this approval so far
    bool    active;     // false = revoked, all future cycles will be rejected
}
```

### EscrowRecord struct

```solidity
struct EscrowRecord {
    address token;    // which token is locked
    uint256 amount;   // gross amount locked (before fee deduction)
    bool    frozen;   // true while a dispute is open — nobody can touch the funds
    bool    released; // true once settled — prevents any second release or refund
}
```

### Enums

```solidity
// All possible invoice states
enum InvoiceStatus { PENDING, ACTIVE, PAID, COMPLETED, CANCELLED, DISPUTED }

// Payment model — determines escrow behaviour
enum PaymentType { PREPAID, POSTPAID }

// Fee calculation mode
enum FeeType { PERCENTAGE, FLAT }
```

---

## 17. Deployment Guide

### Prerequisites

```bash
# Install OpenZeppelin contracts v5.x
npm install @openzeppelin/contracts
```

### Constructor arguments

```solidity
new CryptoPaymentPlatform(
    0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9, // USDT on Arbitrum One
    0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // USDC on Arbitrum One
    250,                                         // 2.5% default platform fee
    0xaf88d065e77c8cC2239327C5EDb3A432268e5831, // subscription paid in USDC
    10_000_000                                   // 10 USDC monthly subscription fee
);
```

### Hardhat deployment script

```javascript
const { ethers } = require("hardhat");

async function main() {
    const USDT = "0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9";
    const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

    const Platform = await ethers.getContractFactory("CryptoPaymentPlatform");
    const platform = await Platform.deploy(
        USDT,
        USDC,
        250,        // 2.5% fee in basis points
        USDC,       // subscription token
        10_000_000  // 10 USDC subscription fee
    );

    await platform.waitForDeployment();
    console.log("Deployed to:", await platform.getAddress());
}

main().catch(console.error);
```

### Foundry deployment script

```solidity
// script/Deploy.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/CryptoPaymentPlatform.sol";

contract DeployScript is Script {
    function run() external {
        vm.startBroadcast();

        new CryptoPaymentPlatform(
            0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9,
            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            250,
            0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            10_000_000
        );

        vm.stopBroadcast();
    }
}
```

```bash
forge script script/Deploy.s.sol \
  --rpc-url $ARBITRUM_RPC \
  --private-key $DEPLOYER_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ARBISCAN_KEY
```

---

## 18. Post-Deployment Configuration

After deploying, complete these steps before opening the platform to users.

### Step 1 — Verify deployment

```solidity
platform.VERSION()           // should return "1.2.0"
platform.owner()             // should return your deployer wallet address
platform.defaultFeeConfig()  // should return (PERCENTAGE, 250, true)
```

### Step 2 — Add employees (optional but recommended)

```solidity
// Add customer support wallets that can resolve disputes
platform.addEmployee(disputeResolverWallet);
platform.addEmployee(customerSupportWallet);
```

### Step 3 — Register initial merchants

```solidity
platform.registerMerchant(merchant1Address);
platform.registerMerchant(merchant2Address);
```

### Step 4 — Configure fees (if not using the deployment default)

```solidity
// Option A: Keep the 2.5% default set at deployment — no action needed

// Option B: Switch to flat fees per token
platform.setDefaultFlatFee(usdtAddress, 1_000_000);               // 1 USDT flat
platform.setDefaultFlatFee(usdcAddress, 1_000_000);               // 1 USDC flat
platform.setDefaultFlatFee(address(0),  500_000_000_000_000);     // 0.0005 ETH flat

// Option C: Give a specific merchant a discounted rate
platform.setUserFee(vipMerchantAddress, FeeType.PERCENTAGE, 100); // 1% for VIPs
```

### Step 5 — Set open invoice cap (optional)

```solidity
platform.setMaxOpenInvoices(100); // max 100 concurrent open invoices per merchant; 0 = unlimited
```

### Step 6 — Add additional tokens (optional)

```solidity
// Add Wrapped ETH (WETH) with 18 decimals
platform.addSupportedToken(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, 18);
```

---

## 19. Security Model

### OpenZeppelin security primitives

| Primitive | What it does |
|-----------|-------------|
| `Ownable` | Enforces single-admin ownership pattern. Only one wallet can hold admin role at a time. |
| `ReentrancyGuard` | Applied to every function that sends ETH or calls `safeTransfer`. Prevents an attacker's contract from calling back in during an execution and exploiting partially-updated state. |
| `Pausable` | Global circuit breaker. Admin can freeze all state-changing operations instantly in an emergency. |
| `SafeERC20` | Wraps all ERC-20 calls so they revert properly even with non-standard tokens that return `false` instead of reverting on failure. |

### Checks-Effects-Interactions (CEI) pattern

Every fund-moving function follows this strict order:

1. **Checks** — validate all inputs, roles, balances, and invoice state. If anything is wrong, revert here.
2. **Effects** — update all internal storage (ledger balances, escrow records, invoice status, nonces). Everything is finalized before any external call is made.
3. **Interactions** — external calls last (`safeTransfer`, `.call{value}`). By this point all state is final, so a reentrancy call cannot observe inconsistent state.

### Escrow double-release protection

`EscrowRecord.released` is set to `true` before any fund movement begins. Every escrow-touching function checks this flag first. A reentrancy attempt or a duplicate call will always hit `EscrowAlreadyReleased` and revert.

### Frozen escrow invariant

When `EscrowRecord.frozen == true`, `markComplete` reverts with `EscrowFrozen`. The only code paths that can unfreeze escrow are `resolveDispute`, `adminReleaseToMerchant`, and `adminRefundToPayer` — all of which require the `onlyAdminOrEmployee` modifier.

### Replay protection

- The `deadline` parameter on `payPrepaidInvoice` and `payPostpaidInvoice` prevents a stale signed transaction from being processed after the payer intended it to expire.
- `nonces[user]` increments on every settled payment for use in off-chain signature verification schemes.

### Withdrawal always allowed for delisted tokens

`withdrawToken` does not check the supported token whitelist. If an admin removes a token, existing holders are never trapped — they can always withdraw their balance. Only new deposits and invoices for that token are blocked.

### Pause covers all entry points

The `receive()` function (which handles direct ETH sends to the contract address) checks `paused()` and reverts with `EnforcedPause()` when the contract is paused. This ensures no funds enter the contract during an emergency freeze.

### Fee-on-transfer token safety

`depositToken` uses a balance-before / balance-after pattern to credit only the amount actually received. This prevents over-crediting on tokens that deduct a fee from every transfer.

### Integer overflow

Solidity `^0.8.20` has built-in overflow protection on all arithmetic. `unchecked` blocks are used only for loop counters and the invoice ID counter — both of which would require 2^256 iterations to overflow, which is physically impossible.

### Admin key risk

If the admin wallet is compromised, an attacker can:
- Pause the contract (blocking all user operations)
- Transfer ownership to themselves
- Steal the admin's accumulated fee balance by calling `withdrawToken`

An attacker **cannot** directly steal user ledger balances or move escrowed funds to arbitrary wallets through any contract function.

### Recommended admin setup

Use a Gnosis Safe multisig wallet as the contract owner with at least a 2-of-3 signer configuration. This eliminates any single point of failure for the admin key and is standard practice for production DeFi deployments.

---

## 20. Gas Optimization

> Gas is the transaction fee on Arbitrum. Lower gas means cheaper operations. This section explains the cost of each operation and why the internal ledger design is more efficient than traditional on-chain payments.

### Gas costs by operation

| Operation | Approximate gas | Notes |
|-----------|----------------|-------|
| Internal payment (ledger update only) | 5,000 – 10,000 | Just two number updates in the contract's database |
| ERC-20 deposit | ~65,000 | Includes the external `safeTransferFrom` call to the token contract |
| ERC-20 withdrawal | ~45,000 | Includes the external `safeTransfer` call |
| ETH deposit | ~25,000 | Simple balance update and event |
| ETH withdrawal | ~30,000 | Balance update plus low-level ETH send |
| Create invoice | ~120,000 – 180,000 | Struct storage, two array pushes, description string |
| Pay prepaid invoice | ~60,000 | Two balance updates plus escrow record creation |
| Mark complete | ~50,000 | Escrow read plus two ledger credits |
| Pay postpaid invoice | ~55,000 | Pure ledger updates, no escrow |
| Trigger recurring | ~70,000 | Ledger updates plus approval record update |
| Raise dispute | ~30,000 | Two storage flag updates plus events |
| Resolve dispute | ~55,000 | Ledger credits plus escrow flags |

### Why internal transfers are cheaper than regular token transfers

A normal ERC-20 `transfer` costs ~65,000 gas because it:
1. Makes an external call to the token contract
2. Updates two storage slots in that external contract
3. Emits a Transfer event in the external contract

An internal ledger payment in this contract:
1. Updates two storage slots in this single contract (already warm in memory if the user just interacted)
2. Emits lightweight events

On Arbitrum, storage access costs are already much lower than Ethereum mainnet. The internal ledger design eliminates external contract calls entirely on payment paths, making it even more advantageous.

### Gas optimization decisions in this contract

- `unchecked` arithmetic on loop counters and invoice ID counter (safe; values cannot realistically overflow)
- Custom errors instead of revert strings (saves calldata bytes per failed transaction)
- `calldata` instead of `memory` for all array and string parameters in external functions (cheaper to read)
- Separate `isEmployee` mapping for O(1) role checking without loading the full `UserConfig` struct
- Escrow and ledger are separate mappings — accessing escrow data does not load user configuration

---

## 21. Integration Guide

### JavaScript with ethers.js

```javascript
import { ethers } from "ethers";
import abi from "./CryptoPaymentPlatform.json"; // ABI from compiled contract

const provider = new ethers.JsonRpcProvider(ARBITRUM_RPC_URL);
const signer   = new ethers.Wallet(PRIVATE_KEY, provider);
const platform = new ethers.Contract(CONTRACT_ADDRESS, abi, signer);

// --- Deposit 100 USDT ---
const usdt = new ethers.Contract(USDT_ADDRESS, ERC20_ABI, signer);
await usdt.approve(CONTRACT_ADDRESS, 100_000_000n);    // approve 100 USDT
await platform.depositToken(USDT_ADDRESS, 100_000_000n); // deposit

// --- Create a prepaid invoice ---
const tx = await platform.createInvoice(
    payerAddress,
    USDT_ADDRESS,
    500_000_000n,           // 500 USDT
    BigInt(Math.floor(Date.now() / 1000) + 7 * 86400), // 7 days from now
    "Website development",
    0,                      // PaymentType.PREPAID = 0
    false,                  // not recurring
    0n,
    0n
);
const receipt = await tx.wait();

// --- Parse the invoice ID from the emitted event ---
const event   = receipt.logs.find(
    l => l.topics[0] === platform.interface.getEvent("InvoiceCreated").topicHash
);
const decoded   = platform.interface.decodeEventLog("InvoiceCreated", event.data, event.topics);
const invoiceId = decoded.invoiceId;

// --- Pay the invoice ---
const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600); // 1 hour deadline
await platform.payPrepaidInvoice(invoiceId, deadline);

// --- Check your internal balance ---
const balance = await platform.balanceOf(walletAddress, USDT_ADDRESS);
console.log("USDT balance:", ethers.formatUnits(balance, 6)); // format with 6 decimals

// --- Preview what the fee split will be before paying ---
const [fee, net] = await platform.previewFee(merchantAddress, 500_000_000n, USDT_ADDRESS);
console.log("Platform fee:", ethers.formatUnits(fee, 6));
console.log("Merchant receives:", ethers.formatUnits(net, 6));
```

### Listening for events (backend / webhook equivalent)

```javascript
// Real-time listener for new invoices
platform.on("InvoiceCreated", (invoiceId, merchant, payer, amount, token, paymentType, isRecurring) => {
    console.log(`New invoice #${invoiceId}: ${ethers.formatUnits(amount, 6)} USDT from merchant ${merchant}`);
    // Trigger your backend notification / database update here
});

// Alert admin team when disputes are raised
platform.on("DisputeRaised", (invoiceId, payer, reason) => {
    notifyAdminTeam({ invoiceId: invoiceId.toString(), payer, reason });
});

// Track all incoming payments for a specific merchant
const filter = platform.filters.InternalTransfer(null, merchantAddress, null, null);
const events = await platform.queryFilter(filter, fromBlock, toBlock);

// Track when open invoice cap changes
platform.on("MaxOpenInvoicesUpdated", (newLimit) => {
    console.log(`Open invoice cap changed to: ${newLimit}`);
});
```

### Indexing with The Graph

Key entities to track and how to build them from events:

| Entity | Created by | Updated by |
|--------|-----------|-----------|
| `Invoice` | `InvoiceCreated` | `InvoicePaid`, `InvoiceCancelled`, `InvoiceMarkedComplete`, `DisputeRaised`, `DisputeResolved`, `RecurringInvoiceTriggered` |
| `User` | `UserRegistered`, `EmployeeAdded` | `UserRoleUpdated`, `UserFeeTierUpdated` |
| `Deposit` / `Withdrawal` | `Deposit`, `Withdrawal` | — |
| `Escrow` | `FundsLocked` | `FundsReleased`, `FundsRefunded`, `FundsHeld` |
| `Dispute` | `DisputeRaised` | `DisputeResolved` |
| `FeeCollection` | `FeeDeducted` | — |
| `PlatformConfig` | deployment | `MaxOpenInvoicesUpdated`, `FeeConfigUpdated`, `FlatFeeUpdated`, `TokenAdded`, `TokenRemoved` |

---

## 22. Emergency Procedures

### Scenario 1 — Suspected exploit or critical bug

**Immediate action — pause everything:**
```solidity
platform.pause(); // blocks ALL state changes and ETH deposits instantly
```

**Assessment — read contract state to identify impact:**
```javascript
// Find all users who ever deposited (from events)
const deposits = await platform.queryFilter(platform.filters.Deposit());
const users    = [...new Set(deposits.map(e => e.args.user))];
const tokens   = [ethers.ZeroAddress, USDT_ADDRESS, USDC_ADDRESS];

// Find all invoices with unreleased escrow
const locked   = await platform.queryFilter(platform.filters.FundsLocked());
const released = await platform.queryFilter(platform.filters.FundsReleased());
const refunded = await platform.queryFilter(platform.filters.FundsRefunded());
const settledIds = new Set([
    ...released.map(e => e.args.invoiceId.toString()),
    ...refunded.map(e => e.args.invoiceId.toString())
]);
const escrowIds = locked
    .map(e => e.args.invoiceId)
    .filter(id => !settledIds.has(id.toString()));
```

**Recovery — return all funds to users:**
```javascript
// Call in batches if user list is very large (avoid block gas limit)
await platform.emergencyWithdrawAll(users, tokens, escrowIds);
```

The function is safe to call multiple times — already-zero balances and already-released escrows are silently skipped.

> **After the emergency sweep:** Users whose ETH send failed during the sweep will have their ETH credited to their internal ledger as a fallback. Once admin unpauses the contract, they can call `withdrawETH` to recover it.

### Scenario 2 — Admin key compromised

If the admin wallet is compromised before you can pause:
- The attacker can pause the contract themselves (blocking all users — not ideal but they can also unpause)
- The attacker can drain the admin's accumulated fee balance via `withdrawToken`
- The attacker **cannot** steal individual user ledger balances directly
- The attacker can transfer ownership, permanently locking out the original admin

**Prevention:** Always use a Gnosis Safe multisig (2-of-3 or higher) as the contract owner. A single compromised key cannot execute transactions on a multisig without additional signatures.

### Scenario 3 — Mass dispute or spam surge

Batch-cancel any PENDING or ACTIVE spam invoices in one transaction:

```solidity
uint256[] memory ids = new uint256[](3);
ids[0] = 101; ids[1] = 102; ids[2] = 103;
platform.batchCancelInvoices(ids, "Platform maintenance — spam removal");
```

For PAID or DISPUTED invoices with locked escrow, resolve them individually:
```solidity
// Refund payer for each affected invoice
platform.adminRefundToPayer(invoiceId);
```

---

## 23. Upgrade Path

This contract is intentionally not upgradeable (no proxy pattern). The design decision prioritises:
- Simplicity and auditability — one file, one deployment, no hidden logic
- No proxy overhead gas cost
- No risk of storage collision from upgrade mistakes

### Migrating to a new version

1. Deploy the new contract version
2. Pause the old contract
3. Call `emergencyWithdrawAll` on the old contract to return all funds to their owners
4. Announce the new contract address to all merchants and payers
5. Merchants re-create their active invoices on the new contract
6. Users re-deposit into the new contract

### What cannot be automatically migrated

| Data | What happens |
|------|-------------|
| Internal ledger balances | Returned to users via emergency withdrawal; users re-deposit |
| Invoice history | Permanently queryable from the old contract's event logs — never lost |
| Active escrows | Refunded to payers via emergency withdrawal |
| Recurring approvals | Payers re-grant approvals on the new contract |

### Preserving history

All events are permanently stored on-chain. A complete historical record of every invoice, payment, dispute, and resolution remains queryable from the old contract indefinitely, even after migrating to a new version.

---

## 24. Changelog

### v1.2.0 (current)

Six security and correctness fixes applied after a full internal audit:

**Critical fixes:**

1. **`withdrawToken` — delisted token withdrawal unblocked**
   Removed the `onlySupportedToken` modifier from `withdrawToken`. Previously, if an admin delisted a token, any user holding a balance in that token could not withdraw it — funds were permanently trapped. Now users can always withdraw balances regardless of the token's current whitelist status. The whitelist only controls new deposits and invoice creation.

2. **`receive()` — pause guard added**
   The fallback function that handles direct ETH sends to the contract address now checks `paused()` and reverts with `EnforcedPause()` when the contract is paused. Previously, users could still deposit ETH via direct send during an emergency freeze, bypassing the pause mechanism.

**Medium fixes:**

3. **`adminReleaseToMerchant` / `adminRefundToPayer` — status validation added**
   Both admin escrow functions now require the invoice to be in `PAID` or `DISPUTED` status before proceeding. Previously, calling either function on an invoice with no escrow (e.g. a PENDING postpaid invoice) would silently succeed with zero amounts while incorrectly marking the invoice as `COMPLETED` and corrupting the open invoice count.

4. **`resolveDispute` — misleading `FundsHeld` event removed**
   After resolving a dispute and releasing or refunding escrow, the contract was emitting a `FundsHeld` event as an "audit trail". This was semantically incorrect — `FundsHeld` means funds are being frozen, not released. Backend indexers listening to this event would incorrectly interpret a resolved dispute as a new freeze. The `DisputeResolved` event already carries the decision and reason, making the extra emit redundant and harmful.

**Low fixes:**

5. **`setMaxOpenInvoices` — `MaxOpenInvoicesUpdated` event added**
   Configuration changes to the open invoice cap are now emitted as events so backends and indexers can track them without having to poll the contract state.

6. **VERSION bumped to `1.2.0`**

---

### v1.1.0

- Added per-token flat fee support (`defaultFlatFeePerToken`, `_userFlatFeePerToken`) eliminating cross-token decimal mismatch
- Added `ACTIVE` invoice status for mid-stream recurring invoices, preventing merchant self-cancellation after billing starts
- Added `tokenDecimals` registry for frontend/SDK consumers
- Added open invoice counting and `maxOpenInvoicesPerMerchant` cap
- Added `batchCancelInvoices` for admin bulk operations
- Extended `emergencyWithdrawAll` to sweep escrow records in addition to ledger balances
- Added `previewFee(merchant, amount, token)` with correct per-token flat-fee lookup
- `_calculateFee` now accepts `token` parameter for accurate flat-fee resolution
- `removeSupportedToken` now explicitly blocks `address(0)` / ETH
- `setSubscriptionConfig` now validates that the subscription token is whitelisted when fee > 0
- `withdrawAllTokens` ETH failure now restores balance and continues the loop (previously reverted the whole call)
- `createInvoice` now rejects self-invoicing (`payer == msg.sender`)

---

## Contract Constants

| Constant | Value | Description |
|----------|-------|-------------|
| `VERSION` | `"1.2.0"` | Deployed contract version |
| `NATIVE_ETH` | `address(0)` | Internal sentinel representing native ETH in the ledger |
| `BPS_DENOMINATOR` | `10_000` | 100% expressed in basis points (100 bps = 1%) |

---

*Contract: `CryptoPaymentPlatform.sol` — Solidity `^0.8.20` — Arbitrum One / Arbitrum Nova*
