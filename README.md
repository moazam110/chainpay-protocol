# CryptoPaymentPlatform

A production-grade Solidity smart contract for the Arbitrum blockchain that combines a gas-efficient pool-vault internal ledger with a full invoice payment system, escrow management, on-chain dispute resolution, P2P internal transfers, and a tiered loyalty fee system — all in a single deployable contract.

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
13. [P2P Internal Transfers](#13-p2p-internal-transfers)
14. [External Wallet & Withdrawal Permission](#14-external-wallet--withdrawal-permission)
15. [User Tier Classification](#15-user-tier-classification)
16. [Function Reference](#16-function-reference)
17. [Events Reference](#17-events-reference)
18. [Custom Errors Reference](#18-custom-errors-reference)
19. [Data Structures](#19-data-structures)
20. [Deployment Guide](#20-deployment-guide)
21. [Post-Deployment Configuration](#21-post-deployment-configuration)
22. [Security Model](#22-security-model)
23. [Gas Optimization](#23-gas-optimization)
24. [Integration Guide](#24-integration-guide)
25. [Emergency Procedures](#25-emergency-procedures)
26. [Upgrade Path](#26-upgrade-path)
27. [Changelog](#27-changelog)

---

## 1. Project Overview

CryptoPaymentPlatform is a crypto payment infrastructure layer built for the Arbitrum network. It allows merchants to raise invoices and receive payments from customers with the following design goals:

- **Gas efficiency** — internal transfers between users cost 5,000–10,000 gas instead of ~65,000 gas for a normal token transfer, because no tokens physically move between wallets during payment. The contract maintains an internal ledger and only updates numbers in a database-like table.
- **Single custody point** — all funds from all users sit inside one contract. There are no per-user wallet deployments or proxy contracts.
- **Complete payment lifecycle** — supports prepaid (escrow-backed), postpaid (instant settle), and recurring (pull-payment) invoice models in one contract.
- **Built-in dispute resolution** — admin and employees can adjudicate disputes with a configurable payer challenge window to ensure fair outcomes.
- **Flexible fee model** — percentage-based or per-token flat fees, configurable globally or per merchant, with a tiered loyalty discount system.
- **P2P transfers** — users can transfer balances directly to each other with optional fee-free family/friends transfer mode.
- **External wallet security** — users can register an external wallet and require admin approval before any withdrawals are allowed.

**Contract version:** `1.6.0`  
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

### What is a challenge window?

When admin resolves a dispute in the merchant's favour, the payer gets a time window (default 30 days) to challenge that ruling before the money is actually released. If the payer does nothing within that window, anyone can call `finalizeResolution` to complete the release. If the payer disagrees, they call `challengeDispute` to reopen the case for re-adjudication.

Think of it like an appeal period after a court ruling.

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
│  │  _invoices   │  │   _escrow    │  │  _recurring      │  │
│  │  [invoiceId] │  │  [invoiceId] │  │  Approvals       │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
│                                                             │
│  ┌──────────────────┐  ┌──────────────────────────────┐    │
│  │  Fee Config      │  │  User Tiers & External       │    │
│  │  defaultFeeConfig│  │  Wallets                     │    │
│  │  _userFeeConfig  │  │  _userTier / _externalWallet │    │
│  │  _tierDiscount   │  │  _canWithdrawExternal        │    │
│  └──────────────────┘  └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
         ▲ deposit / withdraw (real token transfers)
         ▼
   User Wallets / External
```

**Key principle:** Real ERC-20 or ETH transfers happen only on deposit and withdrawal functions. Every payment, fee deduction, subscription charge, escrow release, and P2P transfer is a pure ledger arithmetic operation — like updating rows in a database. No external token calls occur during payment, which eliminates reentrancy risk on payment paths and keeps gas costs low.

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
- Configure global and per-user fees (`setDefaultFee`, `setDefaultFlatFee`)
- Configure subscription settings (`setSubscriptionConfig`)
- Whitelist and delist tokens (`addSupportedToken`, `removeSupportedToken`)
- Execute emergency withdrawal (`emergencyWithdrawAll`)
- Grant/revoke external withdrawal permission (`setExternalWithdrawPermission`)
- Configure tier discounts (`setTierDiscount`)
- Set monthly free-receive limit (`setFreeReceiveLimit`)
- Configure dispute challenge window duration (`setChallengeWindow`)

### Employee

Employees are wallets granted the employee role by the admin. Multiple employees can be active simultaneously. Useful for a support team that handles disputes without needing full admin access.

Employee capabilities (shared with admin):
- Resolve disputes (`resolveDispute`)
- Force-release or force-refund escrow (`adminReleaseToMerchant`, `adminRefundToPayer`)
- Set and remove per-user fee overrides (`setUserFee`, `setUserFlatFee`, `removeUserFee`)
- Assign user tiers (`setUserTier`)
- Cancel invoices (PENDING or ACTIVE) via `cancelInvoice`

### Merchant

Any wallet registered by the admin via `registerMerchant`. Merchants must have an active subscription (if the subscription system is enabled) to create invoices.

Merchant capabilities:
- Create invoices (`createInvoice`)
- Edit their own PENDING invoices (`editInvoice`)
- Cancel their own PENDING invoices (`cancelInvoice`)
- Signal work is done on prepaid invoices (`markComplete`)
- Claim payment after the payer confirmation window expires (`claimPayment`)
- Trigger recurring payment cycles (`triggerRecurring`)
- Pay their subscription (`paySubscription`)
- Deposit and withdraw funds (like any user)

### Payer

Any wallet address — no registration required. The merchant specifies the payer's wallet address when creating the invoice.

Payer capabilities:
- Pay invoices (`payPrepaidInvoice`, `payPostpaidInvoice`)
- Acknowledge an edited invoice before paying (`acknowledgeInvoice`)
- Reject pending invoices before paying (`rejectInvoice`)
- Confirm completed work to release escrow (`confirmCompletion`)
- Raise disputes after merchant marks complete (`raiseDispute`)
- Reclaim locked escrow if merchant never marks complete after dueDate (`reclaimFunds`)
- Challenge a merchant-wins ruling within the challenge window (`challengeDispute`)
- Grant and revoke recurring payment approvals (`approveRecurring`, `revokeRecurring`)
- Deposit and withdraw funds
- Register an external wallet (`registerExternalWallet`)
- Send P2P transfers (`transferToUser`)

### Access Control Matrix

| Action | Admin | Employee | Merchant | Payer/Any |
|--------|-------|----------|----------|-----------|
| Register merchant | ✅ | ❌ | ❌ | ❌ |
| Add / remove employee | ✅ | ❌ | ❌ | ❌ |
| Pause contract | ✅ | ❌ | ❌ | ❌ |
| Create invoice | ❌ | ❌ | ✅ | ❌ |
| Edit PENDING invoice | ✅ | ✅ | ✅ (own) | ❌ |
| Acknowledge edited invoice | ❌ | ❌ | ❌ | ✅ (payer) |
| Pay invoice | ❌ | ❌ | ❌ | ✅ (payer) |
| Mark complete | ❌ | ❌ | ✅ | ❌ |
| Confirm completion | ❌ | ❌ | ❌ | ✅ (payer) |
| Reclaim funds (after dueDate) | ❌ | ❌ | ❌ | ✅ (payer) |
| Claim payment (after timeout) | ❌ | ❌ | ✅ | ❌ |
| Raise dispute | ❌ | ❌ | ❌ | ✅ (payer) |
| Challenge ruling | ❌ | ❌ | ❌ | ✅ (payer) |
| Resolve dispute | ✅ | ✅ | ❌ | ❌ |
| Finalize resolution | ✅ | ✅ | ✅ | ✅ (after deadline) |
| Set global fee | ✅ | ❌ | ❌ | ❌ |
| Set user fee | ✅ | ✅ | ❌ | ❌ |
| Assign user tier | ✅ | ✅ | ❌ | ❌ |
| Set tier discount | ✅ | ❌ | ❌ | ❌ |
| Grant external withdraw permission | ✅ | ❌ | ❌ | ❌ |
| Register external wallet | ✅ | ✅ | ✅ | ✅ |
| P2P transfer | ✅ | ✅ | ✅ | ✅ |
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
```

> **Note on delisted tokens:** `withdrawToken` intentionally does NOT check whether a token is currently whitelisted. If admin removes a token from the supported list, existing holders can still withdraw their balance. The whitelist only controls whether new deposits and invoices can be created for that token.

> **Note on external wallet registration:** If you have registered an external wallet (see Section 14), you also need admin-granted withdrawal permission before `withdrawETH` or `withdrawToken` will succeed. This is an optional security feature — if you have not registered an external wallet, withdrawals work normally.

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

### Editing an invoice

A merchant can edit any PENDING invoice before the payer has paid. Once the invoice has been paid or cancelled, it can no longer be edited.

```solidity
platform.editInvoice(
    invoiceId,
    600_000_000,               // new amount: 600 USDT (0 = keep current)
    block.timestamp + 14 days, // new due date (0 = keep current)
    "Updated scope: logo + brand guide", // new description ("" = keep current)
    0,                         // new recurring interval (0 = keep current)
    0                          // new max cycles (0 = keep current)
);
```

`recurringInterval` and `maxCycles` are only editable on recurring invoices. Pass `0` or an empty string for any field you do not want to change.

### Invoice lifecycle states

Every invoice moves through states like a state machine. Here is the full flow:

```
              ┌──────────────────────────────┐
              │           PENDING             │ ← created here
              └──────────────────────────────┘
                │           │          │
      payPrepaid│  payPostpaid│  triggerRecurring (1st cycle)
                ▼           ▼          ▼
              PAID      COMPLETED    ACTIVE ──► (more cycles)
                │                      │
   markComplete()│         final cycle │
   (if payer    │                     ▼
    hasn't      │                 COMPLETED
    reclaimed)  ▼
         AWAITING_CONFIRMATION
         (7-day window opens)
                │
   ┌────────────┼─────────────────────────────┐
   │            │                             │
   │ confirmCompletion()    raiseDispute()     │ deadline passed
   │ (payer)                (payer)           │ claimPayment()
   │    ▼                      ▼              │ (merchant)
   │ COMPLETED            DISPUTED            │    ▼
   │                           │             │ COMPLETED
   │               resolveDispute(false)  resolveDispute(true)
   │                           │               │
   │                           ▼               ▼
   │                       COMPLETED   CHALLENGE_PENDING
   │                                          │
   │                         challengeDispute() ◄── payer challenges
   │                                 │
   │                            DISPUTED (re-opened)
   │                                 │
   │                             resolveDispute
   │                                          │
   │                         no challenge + deadline passed
   │                                 │
   │                         finalizeResolution()
   │                                 │
   └────────────────────────────► COMPLETED

   PAID + dueDate passed + merchant never called markComplete
   → payer calls reclaimFunds() → CANCELLED

   Any PENDING or ACTIVE invoice → CANCELLED
   (via cancelInvoice / rejectInvoice / emergencyWithdrawAll)
```

| Status | What it means |
|--------|--------------|
| `PENDING` | Invoice created, waiting for payment or first recurring cycle |
| `ACTIVE` | Recurring invoice: at least one cycle paid, more cycles remaining |
| `PAID` | Payer has paid a prepaid invoice; money is locked in escrow |
| `AWAITING_CONFIRMATION` | Merchant marked work complete; payer has a window to confirm, dispute, or do nothing |
| `COMPLETED` | Invoice fully settled — payer confirmed, timeout elapsed, postpaid settled, or all cycles done |
| `CANCELLED` | Invoice voided by merchant, payer, admin, or emergency shutdown |
| `DISPUTED` | Payer opened a dispute; escrow is frozen, nobody can access the funds |
| `CHALLENGE_PENDING` | Admin ruled merchant-wins; payer has a time window to challenge before funds are released |

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
```

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

**Step 3 — Merchant signals work is done (status: PAID → AWAITING_CONFIRMATION)**
```solidity
platform.markComplete(id);
```

Funds are NOT released yet. A 7-day confirmation window starts. The merchant can call this even after the invoice `dueDate` has passed, as long as the payer has not already reclaimed funds.

**Step 4 — Payer reviews and confirms (status: AWAITING_CONFIRMATION → COMPLETED)**
```solidity
platform.confirmCompletion(id);
```

The contract deducts the platform fee from the escrowed 200 USDT and credits the net amount to the merchant's ledger.

**Alternative — Payer disputes the work**
```solidity
platform.raiseDispute(id, "Deliverable did not match the brief.");
// status → DISPUTED; escrow frozen; admin/employee resolves
```

**Alternative — Payer does nothing; window expires**

After 7 days the merchant can claim:
```solidity
platform.claimPayment(id);
// status → COMPLETED; funds released to merchant minus fee
```

**Alternative — Merchant never acted; due date passed**

If the merchant never called `markComplete()` and the invoice `dueDate` has passed, the payer can reclaim their locked funds:
```solidity
platform.reclaimFunds(id);
// status → CANCELLED; full escrow returned to payer, no fee
```

**Step 5 — Merchant withdraws their earnings (optional)**
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
| Merchant signals complete | `markComplete` | Merchant | Status → `AWAITING_CONFIRMATION`; confirmation window starts |
| Payer confirms work | `confirmCompletion` | Payer | Net → merchant ledger; fee → admin ledger; status → `COMPLETED` |
| Confirmation window expires | `claimPayment` | Merchant | Net → merchant ledger; fee → admin ledger; status → `COMPLETED` |
| Merchant never acted; dueDate passed | `reclaimFunds` | Payer | Full amount → payer ledger (no fee); status → `CANCELLED` |
| Payer disputes after markComplete | `raiseDispute` | Payer (in window) | Escrow frozen; status → `DISPUTED` |
| Dispute: payer wins | `resolveDispute(id, false, reason)` | Admin / Employee | Full amount → payer ledger (no fee deducted) |
| Dispute: merchant wins (stage 1) | `resolveDispute(id, true, reason)` | Admin / Employee | Status → `CHALLENGE_PENDING`; payer has challenge window |
| Payer challenges ruling | `challengeDispute(id, evidence)` | Payer (within window) | Status reverts to `DISPUTED` for re-adjudication |
| Challenge window expires | `finalizeResolution(id)` | Anyone | Net → merchant ledger; fee → admin ledger |
| Admin force-release | `adminReleaseToMerchant(id)` | Admin / Employee | Net → merchant ledger; fee → admin ledger |
| Admin full refund | `adminRefundToPayer(id, escrowAmount)` | Admin / Employee | Full amount → payer ledger (no fee) |
| Admin partial refund | `adminRefundToPayer(id, partialAmount)` | Admin / Employee | `partialAmount` → payer; remainder (minus fee) → merchant |
| Emergency shutdown | `emergencyWithdrawAll(...)` | Admin (paused only) | Full amount → payer's wallet directly |

> **Note:** `adminReleaseToMerchant` and `adminRefundToPayer` accept invoices in `PAID`, `AWAITING_CONFIRMATION`, `DISPUTED`, or `CHALLENGE_PENDING` status — any state where escrow is still populated.

### Partial refunds

`adminRefundToPayer` accepts a `refundAmount` parameter, allowing the admin to issue a partial refund:

```solidity
// Full refund — all escrow back to payer, no fee charged
platform.adminRefundToPayer(invoiceId, escrowAmount); // pass full amount

// Partial refund — 60% back to payer, 40% (minus fee) to merchant
uint256 escrow = 500_000_000; // 500 USDT locked
platform.adminRefundToPayer(invoiceId, 300_000_000); // 300 USDT to payer
// Contract auto-releases remaining 200 USDT to merchant minus platform fee
```

### Inspecting escrow

```solidity
(address token, uint256 amount, bool frozen, bool released) =
    platform.getEscrow(invoiceId);
```

---

## 10. Dispute Resolution

> Disputes work like a chargeback system with a built-in appeals process. If a payer is unhappy after paying a prepaid invoice, they can raise a dispute which freezes the funds. An admin or employee investigates and decides who gets the money — but if they rule in the merchant's favour, the payer still gets a window to appeal before the funds are released.

Only payers can raise disputes, and only on PREPAID invoices in `AWAITING_CONFIRMATION` status — i.e. after the merchant has called `markComplete()` but before the payer has confirmed or the confirmation window has expired. If the merchant has not yet called `markComplete()` and the invoice `dueDate` has passed, the payer should call `reclaimFunds()` instead.

### Raising a dispute

```solidity
// Only valid after merchant calls markComplete() (status = AWAITING_CONFIRMATION)
platform.raiseDispute(invoiceId, "Merchant delivered wrong files, not as agreed.");
```

What happens immediately:
- The escrow is frozen — neither the merchant nor the payer can access the funds
- Invoice status changes to `DISPUTED`
- Events emitted: `DisputeRaised`, `FundsHeld`

### Resolving a dispute

An admin or employee investigates the situation off-chain (checks deliverables, messages, evidence) and then calls:

```solidity
// Decision: merchant wins — opens a challenge window for the payer
platform.resolveDispute(invoiceId, true, "Deliverables verified against brief.");

// Decision: payer wins — full refund immediately, no appeal window
platform.resolveDispute(invoiceId, false, "Merchant missed deadline per contract.");
```

**When payer wins (`false`):**
- Escrow is unfrozen immediately
- Full amount refunded to payer's ledger (no fee)
- Invoice status → `COMPLETED`
- Events: `DisputeResolved` ("REFUND"), `FundsRefunded`

**When merchant wins (`true`) — the challenge window:**
- Invoice status → `CHALLENGE_PENDING`
- A deadline is set (default: 30 days from now)
- Escrow remains frozen until the deadline or a challenge
- Events: `DisputeResolved` ("CHALLENGE_PENDING")

### Payer challenging the ruling

During the challenge window, the payer can reopen the case:

```solidity
platform.challengeDispute(
    invoiceId,
    "Admin did not review the contract clause 4B — merchant missed a key deliverable."
);
```

What happens:
- Invoice status reverts to `DISPUTED`
- Escrow stays frozen
- Admin/employee must adjudicate again
- Events: `DisputeChallenged`, `FundsHeld`

If the payer does not challenge within the window, anyone can call `finalizeResolution` to release funds to the merchant:

```solidity
// Callable by anyone once the challenge deadline has passed
platform.finalizeResolution(invoiceId);
```

### Configuring the challenge window

Admin can adjust how long the payer has to challenge a ruling:

```solidity
// Set challenge window to 7 days (default is 30 days)
platform.setChallengeWindow(7 days);

// Check current challenge window duration
uint256 window = platform.challengeWindowDuration();
```

### Admin force-release and force-refund

These skip the formal dispute flow and are useful for off-chain settled cases:

```solidity
// Admin decides to release to merchant (bypasses challenge window)
platform.adminReleaseToMerchant(invoiceId);

// Admin issues full refund to payer
platform.adminRefundToPayer(invoiceId, escrowAmount);

// Admin issues partial refund (50 USDT of 200 USDT escrow back to payer)
platform.adminRefundToPayer(invoiceId, 50_000_000);
```

Both functions require the invoice to be in `PAID` or `DISPUTED` status.

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

When calculating the fee for a payment, the contract uses this priority order:

```
1. Does this merchant have a custom fee override?
   YES → Use their custom rate (tier discount does NOT apply)
         PERCENTAGE mode: custom basis points
         FLAT mode: custom per-token flat amount

   NO  → Compute base fee from global default:
         PERCENTAGE mode: global basis points
         FLAT mode: global per-token flat amount

         Then apply tier discount (if merchant tier is above STANDARD):
         discounted_fee = base_fee - (base_fee × discount_bps / 10,000)
```

See Section 15 for full details on tier discounts.

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

---

## 13. P2P Internal Transfers

> Users can send their internal ledger balance to any other wallet without going through the invoice system. This works like an internal bank transfer — instant, cheap, and does not require the recipient to be a merchant. A special "family/friends" mode allows fee-free transfers up to a monthly limit.

### Standard transfer

```solidity
// Send 50 USDT to a friend's wallet (platform fee applies)
platform.transferToUser(
    recipientAddress,
    usdtAddress,
    50_000_000,  // 50 USDT
    false        // false = standard transfer (fee applies)
);
```

The platform fee is calculated using the **global default fee config only** — no per-user merchant overrides and no tier discounts. This is intentional: the sender is not acting as a merchant in a P2P context. The net amount after fee is credited to the recipient.

### Family / friends transfer (fee-free up to monthly limit)

```solidity
// Send 50 USDT to a family member (fee-free if under monthly limit)
platform.transferToUser(
    recipientAddress,
    usdtAddress,
    50_000_000,
    true  // true = family transfer (fee-free until monthly limit reached)
);
```

How it works:
- The contract tracks how many family transfers the **recipient** has received in the current 30-day window
- If their count is below `freeReceiveLimit` (default: 5), no fee is charged and the full amount arrives
- If they have already received 5 or more fee-free transfers this month, the normal platform fee applies
- The monthly count is always incremented for family transfers (whether fee was charged or not)

```solidity
// Check how many family transfers a user has received this month
uint256 count = platform.getMonthlyReceiveCount(recipientAddress);

// Admin: change the monthly free-receive limit (default 5)
platform.setFreeReceiveLimit(10); // raise to 10 free transfers per month
```

### Transfer rules

- You cannot transfer to yourself (`CannotTransferToSelf` error)
- The token must be supported (whitelisted)
- Your internal balance must cover the gross amount
- Your per-user nonce is incremented (for off-chain signature schemes)

---

## 14. External Wallet & Withdrawal Permission

> This is a security feature for users who want an extra layer of protection. By registering an external wallet, a user signals that they may be operating in a managed or custodial environment, and an admin must explicitly approve withdrawals before they go through. If you don't register an external wallet, this feature has no effect on you.

### Registering an external wallet

```solidity
// Associate your cold storage wallet with your platform account
platform.registerExternalWallet(coldStorageWalletAddress);
```

Once registered:
- All calls to `withdrawETH` and `withdrawToken` will fail with `ExternalWithdrawNotApproved` until admin grants permission
- The registration is visible on-chain so your backend can track it

Restrictions:
- Cannot register `address(0)` (zero address)
- Cannot register your own wallet address

### Admin granting withdrawal permission

```solidity
// Admin approves withdrawals for a user after KYC/verification
platform.setExternalWithdrawPermission(userAddress, true);

// Admin revokes withdrawal permission (e.g. account under review)
platform.setExternalWithdrawPermission(userAddress, false);
```

### Removing the external wallet registration

A user can remove their external wallet at any time. This immediately restores unrestricted withdrawal access.

```solidity
platform.removeExternalWallet();
```

### Querying status

```solidity
// Check what external wallet a user has registered (address(0) = none)
address ext = platform.getExternalWallet(userAddress);

// Check if a user has admin-granted withdrawal permission
bool permitted = platform.canWithdrawExternal(userAddress);
```

### Flow summary

```
User registers external wallet
          │
          ▼
   withdrawETH / withdrawToken called
          │
          ▼
   Has external wallet? ──NO──► withdraw succeeds normally
          │YES
          ▼
   Has permission? ──NO──► revert ExternalWithdrawNotApproved
          │YES
          ▼
   withdraw succeeds
```

---

## 15. User Tier Classification

> Tiers are a loyalty reward system. When a merchant has no custom fee override, their tier determines how much of a discount they receive on the platform fee. A GOLD merchant pays 20% less fee than the standard rate. This encourages high-volume merchants to stay on the platform.

### Available tiers

| Tier | Default Discount | Example: 2.5% base fee → effective fee |
|------|-----------------|----------------------------------------|
| `STANDARD` | 0% | 2.5% |
| `SILVER` | 10% off base fee | 2.25% |
| `GOLD` | 20% off base fee | 2.0% |
| `PLATINUM` | 30% off base fee | 1.75% |

The discount applies to the computed fee, not the invoice amount. If the base fee on a 1,000 USDT invoice is 25 USDT, a GOLD merchant (20% off the fee) pays 20 USDT instead of 25 USDT, and receives 980 USDT instead of 975 USDT.

> **Important:** The tier discount only applies when the merchant has **no per-user fee override**. If an admin has set a custom fee rate for a merchant, that rate is used directly — the tier discount is ignored for that merchant.

### Assigning tiers

```solidity
// Admin or employee promotes a merchant to GOLD tier
platform.setUserTier(merchantAddress, UserTier.GOLD);

// Check a user's current tier
UserTier tier = platform.getUserTier(merchantAddress);
```

### Customising tier discounts

Admin can change the discount percentage for any tier:

```solidity
// Give PLATINUM members a 50% discount on fees (instead of the default 30%)
platform.setTierDiscount(UserTier.PLATINUM, 5_000); // 5000 bps = 50%

// Remove discount for SILVER tier
platform.setTierDiscount(UserTier.SILVER, 0);
```

Discount is expressed in basis points applied to the computed base fee (max: 10,000 bps = 100% of the fee, i.e. zero fee).

### Discount calculation example

```
Invoice: 1,000 USDT
Global fee: 2.5% (250 bps)
Base fee: 1,000 × 250 / 10,000 = 25 USDT

Merchant tier: GOLD (2,000 bps discount)
Discount on fee: 25 × 2,000 / 10,000 = 5 USDT
Effective fee: 25 - 5 = 20 USDT
Merchant receives: 1,000 - 20 = 980 USDT
```

---

## 16. Function Reference

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
Checks ledger balance, checks external wallet permission (if applicable), deducts (effect first), then sends ETH (interaction last — follows CEI pattern). Reverts if balance is insufficient, ETH transfer fails, or caller has a registered external wallet without withdrawal permission.

---

#### `withdrawToken(address token, uint256 amount)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused
Parameters:
  token  — ERC-20 contract address (not address(0))
  amount — amount in token base units
```
Deducts from the caller's internal ledger, checks external wallet permission (if applicable), then calls `safeTransfer` to send tokens to the caller's wallet. **Does not require the token to be currently whitelisted** — users can always withdraw balances in delisted tokens. Reverts if balance is insufficient or external wallet permission is missing.

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
Creates a new invoice. Validates all inputs (including that payer is not the merchant themselves). Assigns a unique ID and stores the invoice. Returns the new invoice ID. Emits `InvoiceCreated`.

---

#### `editInvoice(uint256 invoiceId, uint256 newAmount, uint256 newDueDate, string newDescription, uint256 newRecurringInterval, uint256 newMaxCycles)`
```
Visibility: external
Modifiers:  whenNotPaused, invoiceExists
Caller:     invoice merchant only, PENDING status only
```
Allows the merchant to update invoice fields before the payer has paid. Pass `0` or empty string for fields you do not want to change. `newRecurringInterval` and `newMaxCycles` are only applied on recurring invoices. Reverts with `InvoiceNotEditable` if the invoice is not PENDING. Emits `InvoiceEdited`.

---

#### `cancelInvoice(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  invoiceExists
Caller:     merchant (PENDING status only) | admin / employee (PENDING or ACTIVE)
```
Sets status to `CANCELLED`. Emits `InvoiceCancelled`.

> **Why can't the merchant cancel an ACTIVE invoice?** ACTIVE means recurring cycles are in progress. Allowing the merchant to cancel mid-stream would let them stop billing after receiving payment for early cycles. Only admin or employee can cancel ACTIVE invoices.

---

#### `rejectInvoice(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  invoiceExists
Caller:     payer only, PENDING status only
```
Payer-side cancellation of an invoice they have not yet paid. Sets status to `CANCELLED`. Emits `InvoiceCancelled`.

---

#### `acknowledgeInvoice(uint256 invoiceId)`
```
Visibility: external
Modifiers:  whenNotPaused, invoiceExists
Caller:     assigned payer only, PENDING status only
```
Re-enables payment after a merchant has edited the invoice. When `editInvoice` is called, `payerAcknowledged` is set to `false` and both `payPrepaidInvoice` and `payPostpaidInvoice` will revert with `InvoiceNotAcknowledged` until the payer calls this. On first-time invoices `payerAcknowledged` starts as `true` so this call is not needed unless the invoice has been edited. Emits `InvoiceAcknowledged`.

---

### Payment functions

#### `payPrepaidInvoice(uint256 invoiceId, uint256 deadline)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only
```
Deducts invoice amount from payer's ledger and locks it in `_escrow[invoiceId]`. Sets status to `PAID`. Increments payer nonce. Reverts if: deadline passed, wrong payment type, wrong invoice status, `payerAcknowledged == false` (invoice was edited and not re-acknowledged), past due date, or insufficient balance. Emits `FundsLocked`, `InvoicePaid`.

---

#### `markComplete(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     invoice merchant only, PAID status only
```
Signals that work is done. Does **not** release funds. Sets status to `AWAITING_CONFIRMATION` and starts the confirmation window (`block.timestamp + confirmationWindow`). Works on `PAID` status regardless of whether `dueDate` has passed, provided the payer has not already called `reclaimFunds()`. Reverts if escrow is frozen or already released. Emits `WorkSubmitted` (not `InvoiceMarkedComplete` — the invoice is not complete yet).

---

#### `confirmCompletion(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only, AWAITING_CONFIRMATION status only
```
Payer accepts the merchant's work, releasing escrowed funds to the merchant minus the platform fee. Sets status to `COMPLETED`. Emits `InvoiceConfirmed`, `InvoiceMarkedComplete`, `FeeDeducted`, `FundsReleased`, `InternalTransfer`.

---

#### `reclaimFunds(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only, PAID status only, after dueDate
```
Payer reclaims their locked escrow when the merchant never called `markComplete()` and the invoice `dueDate` has passed. Full escrow returned to payer with no fee. Sets status to `CANCELLED`. Reverts with `InvoiceDueDateNotPassed` if the `dueDate` has not yet passed. Emits `FundsReclaimed`, `FundsRefunded`, `InvoiceCancelled`.

---

#### `claimPayment(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     invoice merchant only, AWAITING_CONFIRMATION status only, after confirmation deadline
```
Merchant claims their payment after the payer's confirmation window has expired without a `confirmCompletion()` or `raiseDispute()` call. Releases escrow to merchant minus fee. Sets status to `COMPLETED`. Reverts with `ConfirmationWindowNotExpired` if the deadline has not passed. Emits `FeeDeducted`, `FundsReleased`, `InternalTransfer`, `InvoiceMarkedComplete`.

---

#### `payPostpaidInvoice(uint256 invoiceId, uint256 deadline)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     assigned payer only
```
Atomic single-step settlement: deducts gross amount from payer, credits net to merchant, credits fee to admin. Sets status to `COMPLETED`. Increments payer nonce. Reverts with `InvoiceNotAcknowledged` if the merchant edited the invoice and the payer has not yet called `acknowledgeInvoice()`. Emits `FeeDeducted`, `InternalTransfer`, `InvoicePaid`, `InvoiceMarkedComplete`.

---

### Recurring payment functions

#### `approveRecurring(address merchant, address token, uint256 maxPerCycle, uint256 totalLimit)`
```
Visibility: external
Modifiers:  whenNotPaused, onlySupportedToken(token)
Caller:     payer
```
Creates or overwrites a recurring pull-payment authorisation. If `totalLimit == 0`, spending is unlimited. Records the merchant in the payer's approved-merchants list (deduplicated). Overwrites the full approval including resetting `totalSpent` to 0.

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
Executes one billing cycle. Performs 9 sequential validation checks (role, recurring flag, status, max cycles, timing, expiry, approval active, per-cycle limit, total limit). Settles payment from payer's ledger to merchant's ledger (minus fee). Sets status to `ACTIVE` (if cycles remain) or `COMPLETED` (if all done). Emits `FeeDeducted`, `InternalTransfer`, `RecurringInvoiceTriggered`, and optionally `InvoiceMarkedComplete`.

---

### Dispute functions

#### `raiseDispute(uint256 invoiceId, string reason)`
```
Visibility: external
Modifiers:  whenNotPaused, invoiceExists
Caller:     payer only — PREPAID invoices in AWAITING_CONFIRMATION status only
```
Freezes escrow. Sets status to `DISPUTED`. Only valid after the merchant has called `markComplete()` AND while the confirmation window is still open. Reverts with `ConfirmationWindowExpired` if the deadline has already passed — at that point the merchant can call `claimPayment()` instead. Emits `DisputeRaised`, `FundsHeld`.

---

#### `resolveDispute(uint256 invoiceId, bool releaseToMerchant, string reason)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
```
Resolves a DISPUTED invoice.
- `releaseToMerchant = true`: opens a payer challenge window. Status → `CHALLENGE_PENDING`. Emits `DisputeResolved` ("CHALLENGE_PENDING").
- `releaseToMerchant = false`: immediately refunds payer (no fee). Status → `COMPLETED`. Emits `DisputeResolved` ("REFUND"), `FundsRefunded`.

---

#### `challengeDispute(uint256 invoiceId, string evidence)`
```
Visibility: external
Modifiers:  whenNotPaused, invoiceExists
Caller:     payer only — CHALLENGE_PENDING status only, within deadline
```
Reopens a merchant-wins ruling for re-adjudication. Status reverts to `DISPUTED`. Reverts with `ChallengeWindowExpired` if the deadline has passed. Emits `DisputeChallenged`, `FundsHeld`.

---

#### `finalizeResolution(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, invoiceExists
Caller:     anyone — CHALLENGE_PENDING status only, after deadline
```
Finalises a merchant-wins ruling once the payer challenge window has expired. Releases escrow to merchant minus fee. Status → `COMPLETED`. Reverts with `ResolutionNotReady` if deadline has not yet passed. Emits `DisputeResolved` ("FINALIZED"), `FeeDeducted`, `FundsReleased`.

---

#### `setChallengeWindow(uint256 duration)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Sets the duration (in seconds) of the payer challenge window after a merchant-wins dispute ruling. Default: 30 days. Minimum: 1 day.

---

#### `setMaxChallenges(uint256 max)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Sets the maximum number of times a payer may challenge a single invoice's dispute ruling. Default: 1. Setting to 0 means no challenges are allowed after the first ruling.

---

#### `setConfirmationWindow(uint256 duration)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Sets how long (in seconds) the payer has to call `confirmCompletion()` or `raiseDispute()` after the merchant calls `markComplete()`. Default: 7 days. Minimum: 1 day.

---

#### `adminReleaseToMerchant(uint256 invoiceId)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
Requires:   invoice status must be PAID, AWAITING_CONFIRMATION, DISPUTED, or CHALLENGE_PENDING
```
Force-releases escrow to merchant outside the formal dispute flow. Bypasses the challenge window. Emits `FeeDeducted`, `FundsReleased`, `InternalTransfer`, `InvoiceMarkedComplete`.

---

#### `adminRefundToPayer(uint256 invoiceId, uint256 refundAmount)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlyAdminOrEmployee, invoiceExists
Requires:   invoice status must be PAID, AWAITING_CONFIRMATION, DISPUTED, or CHALLENGE_PENDING
Parameters:
  refundAmount — amount to return to payer (must be ≤ escrow amount)
```
Refunds some or all of the escrowed amount to the payer.
- **Full refund** (refundAmount == escrow amount): entire escrow to payer, no fee deducted.
- **Partial refund** (refundAmount < escrow amount): `refundAmount` credited to payer; remainder released to merchant minus platform fee.

Reverts with `PartialRefundExceedsEscrow` if `refundAmount > escrow amount`. Emits `FundsRefunded`, and optionally `FeeDeducted` + `FundsReleased` for the merchant portion.

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
Sets global fee mode. For FLAT mode, also call `setDefaultFlatFee` per token. Emits `FeeConfigUpdated`.

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
Sets a per-merchant fee override. When set, tier discounts do not apply to this merchant. Emits `FeeConfigUpdated`, `UserFeeTierUpdated`.

---

#### `setUserFlatFee(address user, address token, uint256 amount)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee, onlySupportedToken(token)
```
Sets a per-token flat fee for a specific merchant. Multiple calls for different tokens are additive. Emits `FlatFeeUpdated`, `UserFeeTierUpdated`.

---

#### `removeUserFee(address user)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee
```
Deletes the merchant's fee override (reverts them to the global default + tier discount). Emits `FeeConfigUpdated`.

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

### P2P transfer functions

#### `transferToUser(address recipient, address token, uint256 amount, bool isFamilyTransfer)`
```
Visibility: external
Modifiers:  nonReentrant, whenNotPaused, onlySupportedToken(token)
Parameters:
  recipient        — destination wallet (cannot be caller)
  token            — supported token including NATIVE_ETH (address(0))
  amount           — gross amount to deduct from caller's ledger
  isFamilyTransfer — if true, no fee when recipient is under their monthly free limit
```
Transfers internal balance from caller to recipient. Fee uses the **global default fee config only** (no per-user overrides, no tier discounts) via `_calculateDefaultFee`. For family transfers, checks recipient's monthly calendar-month receive count and skips fee if under `freeReceiveLimit`; always increments the count. Increments sender nonce. Emits `InternalTransfer`, optionally `FeeDeducted` (with `type(uint256).max` as the invoiceId sentinel to distinguish from invoice fees).

---

#### `setFreeReceiveLimit(uint256 limit)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Sets how many fee-free family transfers a wallet may receive per 30-day window. Default: 5.

---

### External wallet functions

#### `registerExternalWallet(address externalWallet)`
```
Visibility: external
Caller:     any user
```
Associates an external wallet with the caller's account. After registration, `withdrawETH` and `withdrawToken` require admin-granted permission. Reverts with `ZeroAddress` or `CannotRegisterOwnAddress` if invalid. Emits `ExternalWalletRegistered`.

---

#### `removeExternalWallet()`
```
Visibility: external
Caller:     any user
```
Removes the caller's external wallet registration, restoring unrestricted withdrawals. Emits `ExternalWalletRemoved`.

---

#### `setExternalWithdrawPermission(address user, bool value)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Grants or revokes external-withdrawal permission for a user who has a registered external wallet. Emits `ExternalWithdrawPermissionUpdated`.

---

### User tier functions

#### `setUserTier(address user, UserTier tier)`
```
Visibility: external
Modifiers:  onlyAdminOrEmployee
```
Assigns a loyalty tier to a user. Affects the fee discount applied when the user is a merchant without a per-user fee override. Emits `UserTierUpdated`.

---

#### `setTierDiscount(UserTier tier, uint256 discountBps)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  tier        — STANDARD, SILVER, GOLD, or PLATINUM
  discountBps — discount in basis points applied to the computed base fee (max 10,000)
```
Configures the fee discount for a tier. Reverts with `InvalidFeeConfig` if `discountBps > 10,000`.

---

### Admin control functions

#### `pause()` / `unpause()`
```
Visibility: external
Modifiers:  onlyAdmin
```
Pauses or unpauses all state-changing functions (deposits, withdrawals, payments, invoice creation, etc.). Direct ETH sends to the contract address are also blocked while paused. The emergency withdrawal function remains available to admin while paused.

---

#### `addSupportedToken(address token, uint8 decimals)`
```
Visibility: external
Modifiers:  onlyAdmin
Parameters:
  token    — ERC-20 contract address (not address(0))
  decimals — decimal precision of the token (e.g. 6 for USDT/USDC, 18 for WETH)
```
Whitelists a new token and stores its decimal count. `address(0)` is blocked — native ETH is pre-whitelisted in the constructor. Emits `TokenAdded`.

---

#### `removeSupportedToken(address token)`
```
Visibility: external
Modifiers:  onlyAdmin
```
Removes a token from the whitelist. `address(0)` (ETH) can never be removed. Existing balances in the delisted token are unaffected — users can still withdraw. Emits `TokenRemoved`.

---

#### `transferOwnership(address newOwner)`
```
Visibility: public
Modifiers:  onlyOwner
```
Transfers admin role to a new wallet. Emits `AdminTransferred`.

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

**Phase 2 — Escrow sweep:** For each invoice ID in `escrowInvoiceIds`, refunds the escrowed amount to the original payer's wallet and cancels the invoice. If an ETH send fails for a payer, the amount is credited to their internal ledger as a fallback.

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
| `getUserTier(user)` | `UserTier` | Loyalty tier for a user |
| `getExternalWallet(user)` | `address` | Registered external wallet (address(0) = none) |
| `canWithdrawExternal(user)` | `bool` | Whether admin has granted withdrawal permission |
| `getMonthlyReceiveCount(user)` | `uint256` | Family transfers received in current 30-day window |
| `totalInvoices()` | `uint256` | Total invoices ever created (= last invoice ID) |
| `previewFee(merchant, amount, token)` | `(fee, net)` | Simulate a fee split before submitting a transaction |
| `isSubscriptionValid(merchant)` | `bool` | Whether a merchant's subscription is currently active |

---

## 17. Events Reference

> Events are the blockchain equivalent of server-side logs. Your backend or indexing service listens for these events to know when something happened on-chain. Every important action in the contract emits at least one event.

| Event | Parameters | Emitted when |
|-------|-----------|-------------|
| `UserRegistered` | `user, role` | Admin registers a merchant |
| `UserRoleUpdated` | `user, newRole` | Employee added or removed |
| `UserFeeTierUpdated` | `user, FeeConfig` | Per-user fee changed |
| `UserTierUpdated` | `user, tier` | Admin/employee assigns a loyalty tier |
| `Deposit` | `user, token, amount` | Any deposit (function call or direct ETH send) |
| `Withdrawal` | `user, token, amount` | Any successful withdrawal |
| `TokenAdded` | `token, decimals` | Admin whitelists a new token |
| `TokenRemoved` | `token` | Admin removes a token from the whitelist |
| `InvoiceCreated` | `invoiceId, merchant, payer, amount, token, paymentType, isRecurring` | New invoice created |
| `InvoiceEdited` | `invoiceId, editor, timestamp` | Merchant edits a PENDING invoice |
| `InvoiceCancelled` | `invoiceId, reason` | Invoice cancelled or rejected |
| `InvoicePaid` | `invoiceId, payer, amount, timestamp` | Payer pays an invoice |
| `InvoiceMarkedComplete` | `invoiceId, merchant` | Invoice reaches COMPLETED status |
| `RecurringInvoiceTriggered` | `invoiceId, cycleNumber` | One recurring billing cycle executed |
| `FundsLocked` | `invoiceId, amount` | Escrow created when payer pays prepaid invoice |
| `FundsReleased` | `invoiceId, merchant, netAmount` | Escrow released to merchant |
| `FundsRefunded` | `invoiceId, payer, amount` | Escrow refunded to payer |
| `FundsHeld` | `invoiceId, reason` | Escrow frozen (dispute raised or challenge submitted) |
| `DisputeRaised` | `invoiceId, payer, reason` | Payer opens a dispute |
| `DisputeResolved` | `invoiceId, decision, resolver` | Admin resolves a dispute (decision: "CHALLENGE_PENDING", "REFUND", or "FINALIZED") |
| `DisputeChallenged` | `invoiceId, challenger, evidence` | Payer challenges a merchant-wins ruling |
| `FeeDeducted` | `invoiceId, feeAmount, token` | Platform fee credited to admin |
| `FeeConfigUpdated` | `user, FeeConfig` | Global or per-user fee mode changed |
| `FlatFeeUpdated` | `user, token, amount` | Per-token flat fee amount set |
| `AdminTransferred` | `oldAdmin, newAdmin` | Contract ownership transferred |
| `EmployeeAdded` | `employee` | Employee role granted |
| `EmployeeRemoved` | `employee` | Employee role revoked |
| `SubscriptionPaid` | `merchant, expiry` | Merchant pays subscription |
| `InternalTransfer` | `from, to, token, amount` | Any ledger-to-ledger payment (invoices, P2P transfers, subscriptions) |
| `ExternalWalletRegistered` | `user, externalWallet` | User registers an external wallet |
| `ExternalWalletRemoved` | `user` | User removes their external wallet |
| `ExternalWithdrawPermissionUpdated` | `user, canWithdraw` | Admin grants or revokes withdrawal permission |
| `SubscriptionConfigUpdated` | `token, fee, duration` | Admin reconfigures the subscription system |
| `InvoiceAcknowledged` | `invoiceId, payer` | Payer acknowledges an edited invoice, re-enabling payment |
| `WorkSubmitted` | `invoiceId, merchant` | Merchant calls `markComplete()` — work claimed done; confirmation window starts |
| `InvoiceConfirmed` | `invoiceId, payer` | Payer confirms work is complete, releasing escrow to merchant |
| `FundsReclaimed` | `invoiceId, payer` | Payer reclaimed locked escrow after merchant failed to call `markComplete()` before `dueDate` |

---

## 18. Custom Errors Reference

> Custom errors are more gas-efficient than error strings and give you precise, programmatic error handling. When a transaction reverts, decode the error to understand exactly what went wrong.

| Error | Parameters | What caused it |
|-------|-----------|---------------|
| `Unauthorized()` | — | Caller does not have the required role for this action |
| `TokenNotSupported(token)` | `address` | Token is not on the whitelist |
| `InsufficientBalance(user, token, required, available)` | addresses + uint | Internal ledger balance is too low for this operation |
| `InvoiceNotFound(invoiceId)` | `uint256` | No invoice exists for this ID |
| `InvalidInvoiceStatus(invoiceId, current)` | `uint256, InvoiceStatus` | The invoice is in the wrong state for this operation |
| `InvoiceDueDatePassed(invoiceId)` | `uint256` | The invoice's due date has already passed |
| `InvoiceNotEditable(invoiceId)` | `uint256` | Invoice is not in PENDING status and cannot be edited |
| `EscrowFrozen(invoiceId)` | `uint256` | A dispute is open — escrow is locked |
| `EscrowAlreadyReleased(invoiceId)` | `uint256` | Escrow was already settled (prevents double-release) |
| `PartialRefundExceedsEscrow(invoiceId, requested, available)` | `uint256 × 3` | refundAmount is greater than the total escrowed amount |
| `RecurringNotApproved()` | — | Payer's recurring approval is inactive or does not exist |
| `RecurringLimitExceeded()` | — | This cycle would exceed the per-cycle or total budget limit |
| `MaxCyclesReached(invoiceId)` | `uint256` | All billing cycles for this invoice have been completed |
| `TooEarlyForCycle(invoiceId, nextDue)` | `uint256, uint256` | The next billing date has not arrived yet |
| `SubscriptionExpired(merchant)` | `address` | Merchant's subscription has lapsed |
| `InvalidAmount()` | — | Amount is zero, or recurring parameters are invalid |
| `InvalidFeeConfig()` | — | Basis points value exceeds 10,000 (would mean >100% fee) |
| `TransactionExpired()` | — | `block.timestamp > deadline` parameter |
| `ZeroAddress()` | — | A disallowed zero address was passed |
| `ContractMustBePaused()` | — | `emergencyWithdrawAll` called while contract is live, or direct ETH sent to contract while paused |
| `ChallengeWindowExpired(invoiceId, deadline)` | `uint256, uint256` | Payer tried to challenge a dispute ruling after the challenge deadline passed |
| `ResolutionNotReady(invoiceId, readyAt)` | `uint256, uint256` | `finalizeResolution` called before the challenge deadline |
| `CannotTransferToSelf()` | — | Caller tried to `transferToUser` with their own address as recipient |
| `CannotRegisterOwnAddress()` | — | Tried to register own wallet as external wallet |
| `ExternalWithdrawNotApproved(user)` | `address` | User has external wallet registered but no withdrawal permission granted |
| `MaxChallengesReached(invoiceId)` | `uint256` | Payer has already challenged this invoice the maximum allowed number of times |
| `InvoiceNotAcknowledged(invoiceId)` | `uint256` | Merchant edited the invoice but payer has not yet called `acknowledgeInvoice()` |
| `ConfirmationWindowNotExpired(invoiceId, deadline)` | `uint256, uint256` | `claimPayment` called before the payer confirmation window has expired |
| `ConfirmationWindowExpired(invoiceId, deadline)` | `uint256, uint256` | `raiseDispute` called after the payer confirmation window has already expired |
| `InvoiceDueDateNotPassed(invoiceId)` | `uint256` | `reclaimFunds` called before the invoice `dueDate` has passed |

---

## 19. Data Structures

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
    bool          payerAcknowledged; // false after editInvoice; payer must re-ack before paying
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
enum InvoiceStatus {
    PENDING,                // created, awaiting payment
    ACTIVE,                 // recurring: 1+ cycles paid, more remaining
    PAID,                   // prepaid: payer paid, funds in escrow
    AWAITING_CONFIRMATION,  // merchant marked complete; payer has window to confirm or dispute
    COMPLETED,              // fully settled
    CANCELLED,              // voided
    DISPUTED,               // dispute open, escrow frozen
    CHALLENGE_PENDING       // merchant-wins ruling; payer challenge window open
}

// Payment model — determines escrow behaviour
enum PaymentType { PREPAID, POSTPAID }

// Fee calculation mode
enum FeeType { PERCENTAGE, FLAT }

// User loyalty tier — affects fee discount
enum UserTier { STANDARD, SILVER, GOLD, PLATINUM }
```

---

## 20. Deployment Guide

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

## 21. Post-Deployment Configuration

After deploying, complete these steps before opening the platform to users.

### Step 1 — Verify deployment

```solidity
platform.VERSION()                  // should return "1.6.0"
platform.owner()                    // should return your deployer wallet address
platform.defaultFeeConfig()         // should return (PERCENTAGE, 250, true)
platform.challengeWindowDuration()  // should return 30 days (2592000 seconds)
platform.confirmationWindow()       // should return 7 days (604800 seconds)
platform.freeReceiveLimit()         // should return 5
platform.maxChallengesPerInvoice()  // should return 1
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

### Step 5 — Configure tier discounts (optional)

```solidity
// Defaults are already set in the constructor:
// SILVER = 1,000 bps (10% off fee), GOLD = 2,000 bps (20%), PLATINUM = 3,000 bps (30%)

// Override if you want different values:
platform.setTierDiscount(UserTier.PLATINUM, 5_000); // 50% off for platinum
```

### Step 6 — Assign tiers to high-value merchants (optional)

```solidity
platform.setUserTier(highVolumeMerchant, UserTier.GOLD);
platform.setUserTier(enterpriseMerchant, UserTier.PLATINUM);
```

### Step 7 — Configure dispute challenge window (optional)

```solidity
// Default is 30 days; shorten if you want faster dispute resolution
platform.setChallengeWindow(7 days); // 7-day challenge window
```

### Step 8 — Configure prepaid confirmation window (optional)

```solidity
// Default is 7 days; adjust based on your typical turnaround expectations
platform.setConfirmationWindow(3 days); // payer has 3 days to confirm or dispute
```

### Step 10 — Configure monthly free-receive limit (optional)

```solidity
// Default is 5; raise or lower based on your use case
platform.setFreeReceiveLimit(10); // allow 10 fee-free family transfers per month
```

### Step 11 — Add additional tokens (optional)

```solidity
// Add Wrapped ETH (WETH) with 18 decimals
platform.addSupportedToken(0x82aF49447D8a07e3bd95BD0d56f35241523fBab1, 18);
```

---

## 22. Security Model

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

When `EscrowRecord.frozen == true`, `markComplete` reverts with `EscrowFrozen`. The only code paths that can unfreeze escrow are `resolveDispute` (refund path), `adminReleaseToMerchant`, `adminRefundToPayer`, and `finalizeResolution` — all of which are gated on appropriate access controls.

### Dispute challenge window prevents hasty rulings

The challenge window (`CHALLENGE_PENDING` status) ensures payers have time to appeal a merchant-wins ruling. Funds remain frozen during the window. If the payer challenges, the case returns to `DISPUTED` for re-examination. This prevents a scenario where a rushed or incorrect admin ruling permanently transfers funds to the wrong party.

### External wallet withdrawal gating

Users who register an external wallet cannot withdraw until admin grants permission. This is useful for:
- Custodial accounts where an operator manages funds
- KYC-verified withdrawal flows
- Accounts under compliance review

The gating is opt-in — users without a registered external wallet are unaffected.

### Replay protection

- The `deadline` parameter on `payPrepaidInvoice` and `payPostpaidInvoice` prevents a stale signed transaction from being processed after the payer intended it to expire.
- `nonces[user]` increments on every settled payment and P2P transfer for use in off-chain signature verification schemes.

### Withdrawal always allowed for delisted tokens

`withdrawToken` does not check the supported token whitelist. If an admin removes a token, existing holders are never trapped — they can always withdraw their balance. Only new deposits and invoices for that token are blocked.

### Pause covers all entry points

The `receive()` function (which handles direct ETH sends to the contract address) checks `paused()` and reverts with `ContractMustBePaused()` when the contract is paused. This ensures no funds enter the contract during an emergency freeze.

### Fee-on-transfer token safety

`depositToken` uses a balance-before / balance-after pattern to credit only the amount actually received. This prevents over-crediting on tokens that deduct a fee from every transfer.

### Integer overflow

Solidity `^0.8.20` has built-in overflow protection on all arithmetic. `unchecked` blocks are used only for loop counters and the invoice ID counter — both of which would require 2^256 iterations to overflow, which is physically impossible.

### Tier discount cannot exceed 100% of fee

`setTierDiscount` validates that `discountBps <= 10,000` (BPS_DENOMINATOR). This ensures the effective fee is always `>= 0` — a merchant can receive a zero fee but never a negative fee (which would mean the platform pays merchants).

### Admin key risk

If the admin wallet is compromised, an attacker can:
- Pause the contract (blocking all user operations)
- Transfer ownership to themselves
- Steal the admin's accumulated fee balance by calling `withdrawToken`
- Grant arbitrary withdrawal permissions

An attacker **cannot** directly steal user ledger balances or move escrowed funds to arbitrary wallets through any contract function.

### Recommended admin setup

Use a Gnosis Safe multisig wallet as the contract owner with at least a 2-of-3 signer configuration. This eliminates any single point of failure for the admin key and is standard practice for production DeFi deployments.

---

## 23. Gas Optimization

> Gas is the transaction fee on Arbitrum. Lower gas means cheaper operations. This section explains the cost of each operation and why the internal ledger design is more efficient than traditional on-chain payments.

### Gas costs by operation

| Operation | Approximate gas | Notes |
|-----------|----------------|-------|
| Internal payment (ledger update only) | 5,000 – 10,000 | Just two number updates in the contract's database |
| P2P transfer | 30,000 – 50,000 | Ledger updates + monthly count read/write for family transfers |
| ERC-20 deposit | ~65,000 | Includes the external `safeTransferFrom` call to the token contract |
| ERC-20 withdrawal | ~45,000 | Includes the external `safeTransfer` call |
| ETH deposit | ~25,000 | Simple balance update and event |
| ETH withdrawal | ~30,000 | Balance update plus low-level ETH send |
| Create invoice | ~120,000 – 180,000 | Struct storage, two array pushes, description string |
| Edit invoice | ~30,000 – 50,000 | Storage writes for changed fields only |
| Pay prepaid invoice | ~60,000 | Two balance updates plus escrow record creation |
| Mark complete | ~50,000 | Escrow read plus two ledger credits |
| Pay postpaid invoice | ~55,000 | Pure ledger updates, no escrow |
| Trigger recurring | ~70,000 | Ledger updates plus approval record update |
| Raise dispute | ~30,000 | Two storage flag updates plus events |
| Resolve dispute (refund) | ~50,000 | Ledger credits plus escrow flags |
| Resolve dispute (challenge window) | ~35,000 | Just sets deadline, no fund movement |
| Challenge dispute | ~25,000 | Status change plus event |
| Finalize resolution | ~60,000 | Same as a normal escrow release |

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
- Tier discount lookup is a single mapping read — no loops or array searches
- External wallet permission check is two mapping reads — minimal overhead on every withdrawal

---

## 24. Integration Guide

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

// --- Send a P2P transfer (family mode) ---
await platform.transferToUser(
    recipientAddress,
    USDT_ADDRESS,
    50_000_000n,  // 50 USDT
    true          // family transfer — fee-free if under monthly limit
);

// --- Check a user's tier ---
// Tier enum: 0=STANDARD, 1=SILVER, 2=GOLD, 3=PLATINUM
const tier = await platform.getUserTier(merchantAddress);
console.log("Merchant tier:", ["STANDARD", "SILVER", "GOLD", "PLATINUM"][tier]);
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

// Track challenge window openings (merchant-wins rulings)
platform.on("DisputeResolved", (invoiceId, decision, resolver) => {
    if (decision === "CHALLENGE_PENDING") {
        console.log(`Invoice #${invoiceId} in challenge window — notify payer`);
    }
});

// Track when a payer challenges a ruling
platform.on("DisputeChallenged", (invoiceId, challenger, evidence) => {
    console.log(`Invoice #${invoiceId} challenged by ${challenger}: ${evidence}`);
    // Re-open the dispute ticket in your support system
});

// Track all incoming payments for a specific merchant
const filter = platform.filters.InternalTransfer(null, merchantAddress, null, null);
const events = await platform.queryFilter(filter, fromBlock, toBlock);

// Track external wallet registrations
platform.on("ExternalWalletRegistered", (user, externalWallet) => {
    console.log(`User ${user} registered external wallet ${externalWallet}`);
    // Trigger KYC / approval workflow
});
```

### Indexing with The Graph

Key entities to track and how to build them from events:

| Entity | Created by | Updated by |
|--------|-----------|-----------|
| `Invoice` | `InvoiceCreated` | `InvoiceEdited`, `InvoicePaid`, `InvoiceCancelled`, `InvoiceMarkedComplete`, `DisputeRaised`, `DisputeResolved`, `DisputeChallenged`, `RecurringInvoiceTriggered` |
| `User` | `UserRegistered`, `EmployeeAdded` | `UserRoleUpdated`, `UserFeeTierUpdated`, `UserTierUpdated` |
| `Deposit` / `Withdrawal` | `Deposit`, `Withdrawal` | — |
| `Escrow` | `FundsLocked` | `FundsReleased`, `FundsRefunded`, `FundsHeld` |
| `Dispute` | `DisputeRaised` | `DisputeResolved`, `DisputeChallenged` |
| `FeeCollection` | `FeeDeducted` | — |
| `ExternalWallet` | `ExternalWalletRegistered` | `ExternalWalletRemoved`, `ExternalWithdrawPermissionUpdated` |
| `PlatformConfig` | deployment | `FeeConfigUpdated`, `FlatFeeUpdated`, `TokenAdded`, `TokenRemoved` |

---

## 25. Emergency Procedures

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
- The attacker can pause the contract themselves (blocking all users)
- The attacker can drain the admin's accumulated fee balance via `withdrawToken`
- The attacker can grant withdrawal permission to arbitrary users
- The attacker **cannot** steal individual user ledger balances directly
- The attacker can transfer ownership, permanently locking out the original admin

**Prevention:** Always use a Gnosis Safe multisig (2-of-3 or higher) as the contract owner. A single compromised key cannot execute transactions on a multisig without additional signatures.

### Scenario 3 — Large backlog of unresolved disputes

For PAID or DISPUTED invoices with locked escrow, issue partial refunds where appropriate:

```solidity
// Full refund on clearly meritless merchant claims
platform.adminRefundToPayer(invoiceId, escrowAmount);

// Partial settlement: 80% to payer, 20% to merchant for partial work
uint256 escrow = 500_000_000; // 500 USDT
platform.adminRefundToPayer(invoiceId, 400_000_000); // 400 USDT to payer; 100 USDT to merchant (minus fee)
```

---

## 26. Upgrade Path

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
| User tiers | Admin re-assigns tiers on the new contract |
| External wallet registrations | Users re-register on the new contract |

### Preserving history

All events are permanently stored on-chain. A complete historical record of every invoice, payment, dispute, and resolution remains queryable from the old contract indefinitely, even after migrating to a new version.

---

## 27. Changelog

### v1.6.0 (current)

**Prepaid Confirmation Flow** — `markComplete()` no longer releases escrow immediately. Instead it moves the invoice to the new `AWAITING_CONFIRMATION` status and opens a configurable payer window (default 7 days). Three new paths complete the flow:

- **`confirmCompletion(invoiceId)`** — payer accepts the work; escrow released to merchant minus fee; status → `COMPLETED`.
- **`reclaimFunds(invoiceId)`** — payer reclaims escrow when the merchant never called `markComplete()` and the invoice `dueDate` has passed; full refund, no fee; status → `CANCELLED`.
- **`claimPayment(invoiceId)`** — merchant claims payment after the confirmation window expires without payer action; escrow released to merchant minus fee; status → `COMPLETED`.

**`raiseDispute` scope change** — disputes are now only accepted on `AWAITING_CONFIRMATION` status AND within the confirmation window. The payer cannot dispute while the invoice is still in `PAID` status, nor after the confirmation window has expired.

**Admin functions extended** — `adminReleaseToMerchant` and `adminRefundToPayer` now also accept `AWAITING_CONFIRMATION` status.

New admin function: `setConfirmationWindow(duration)` (minimum 1 day, default 7 days).

New events: `WorkSubmitted` (emitted by `markComplete()` instead of `InvoiceMarkedComplete` — invoice is not yet complete at that point), `InvoiceConfirmed`, `FundsReclaimed`.

New errors: `ConfirmationWindowNotExpired`, `ConfirmationWindowExpired`, `InvoiceDueDateNotPassed`.

New state: `confirmationWindow = 7 days`, `_confirmationDeadline` mapping.

New state: `confirmationWindow = 7 days`, `_confirmationDeadline` mapping.

VERSION bumped to `1.6.0`.

---

### v1.5.0

Twelve targeted fixes:

1. **`receive()` error** — now reverts with the contract's own `ContractMustBePaused()` error instead of the OZ internal `EnforcedPause()`, keeping error naming consistent with the rest of the contract.
2. **`removeExternalWallet` permission check** — requires admin-granted `_canWithdrawExternal` permission before the user can deregister their external wallet. Prevents bypassing the withdrawal gate by simply removing the registered wallet.
3. **Challenge count cap** — new `_challengeCount` mapping, `maxChallengesPerInvoice` (default 1), `setMaxChallenges(max)` admin setter, and `MaxChallengesReached` error. Payers are now limited in how many times they can challenge a single ruling.
4. **`payerAcknowledged` flag** — new `bool payerAcknowledged` field on the `Invoice` struct. Set to `true` on `createInvoice`, set to `false` by `editInvoice`. Both `payPrepaidInvoice` and `payPostpaidInvoice` now check this flag and revert with `InvoiceNotAcknowledged` if the payer has not re-acknowledged an edited invoice. New function: `acknowledgeInvoice()`. New event: `InvoiceAcknowledged`.
5. **Calendar month bucket** — the monthly family-transfer counter now uses a proper calendar month key (`YYYYMM`) computed via the Howard Hinnant `civil-from-days` algorithm instead of a rolling 30-day bucket (`block.timestamp / 30 days`). This makes the limit reset on the 1st of each calendar month as users would naturally expect.
6. **P2P transfer fee isolation** — `transferToUser` now calls a new internal `_calculateDefaultFee` function that uses only the global default fee config, with no per-user merchant overrides and no tier discounts. Senders in a P2P context are not merchants, so applying merchant-specific rates was incorrect.
7. **Minimum fee floor** — if the configured fee rate is non-zero but the arithmetic rounds down to zero (tiny payment amounts), the contract now charges 1 base unit. Applies in both `_calculateFee` and `_calculateDefaultFee`.
8. **`adminRefundToPayer` accepts `CHALLENGE_PENDING`** — admin can now issue refunds on invoices in the challenge window, not only `PAID` and `DISPUTED`.
9. **`editInvoice` guard** — `newMaxCycles < completedCycles` now reverts with `InvalidAmount`. Prevents accidentally setting max cycles below the already-completed count.
10. **`SubscriptionConfigUpdated` event** — emitted at the end of `setSubscriptionConfig` whenever admin reconfigures the subscription system.
11. **`unpause()` modifier** — `unpause` now carries `whenPaused`, making the intent self-documenting and preventing a call when the contract is already live.

VERSION bumped to `1.5.0`.

---

### v1.4.1

Four audit fixes:

1. **`editInvoice` access control** — admin and employee can now edit PENDING invoices (previously only the invoice's merchant could). Consistent with how `cancelInvoice` is gated.
2. **`adminReleaseToMerchant` accepts `CHALLENGE_PENDING`** — admin can force-release to merchant even while a payer challenge window is open, bypassing the window when needed.
3. **`setChallengeWindow` minimum guard** — reverts with `InvalidAmount` if the supplied duration is less than 1 day. Prevents accidentally setting a zero or near-zero window.
4. **`FeeDeducted` P2P sentinel** — `transferToUser` emits `FeeDeducted` with `type(uint256).max` as the `invoiceId` argument. This is a sentinel value distinguishing P2P transfer fees from invoice fees (which always have a real invoice ID). Backends can filter on this to avoid miscounting P2P fees as invoice fees.

VERSION bumped to `1.4.1`.

---

### v1.4.0

Eight new features added:

**Feature 1 — Partial Refund**

`adminRefundToPayer` now accepts a `refundAmount` parameter. When `refundAmount` equals the full escrow amount, behaviour is the same as before (full refund, no fee). When it is less, the requested amount is returned to the payer and the remainder is released to the merchant after deducting the platform fee. New error: `PartialRefundExceedsEscrow`.

**Feature 2 — Invoice Edit**

New `editInvoice` function allows merchants to update a PENDING invoice's amount, due date, description, and (for recurring invoices) cycle interval and max cycles. Once an invoice moves out of PENDING status it can no longer be edited. New event: `InvoiceEdited`. New error: `InvoiceNotEditable`.

**Feature 3 — Dispute Challenge Window**

`resolveDispute` on the merchant-wins path no longer releases funds immediately. Instead it sets the invoice to `CHALLENGE_PENDING` and records a deadline (default: 30 days). During this window, the payer can call `challengeDispute` with evidence to reopen the case. After the deadline, anyone calls `finalizeResolution` to complete the release. New functions: `challengeDispute`, `finalizeResolution`, `setChallengeWindow`. New status: `CHALLENGE_PENDING`. New public variable: `challengeWindowDuration`. New events: `DisputeChallenged`. New errors: `ChallengeWindowExpired`, `ResolutionNotReady`.

**Feature 4 — P2P Internal Transfer**

New `transferToUser` function enables any user to send internal ledger balance directly to another user without an invoice. Platform fee applies (calculated on the sender's tier/override). Supports all whitelisted tokens including ETH. New error: `CannotTransferToSelf`.

**Feature 5 — External Wallet Registration**

New `registerExternalWallet`, `removeExternalWallet`, and `getExternalWallet` functions. Users can associate an external wallet address with their account. This is used in combination with Feature 6. New events: `ExternalWalletRegistered`, `ExternalWalletRemoved`. New error: `CannotRegisterOwnAddress`.

**Feature 6 — External Withdrawal Permission**

`withdrawETH` and `withdrawToken` now check whether the caller has a registered external wallet. If they do, admin must explicitly grant withdrawal permission via `setExternalWithdrawPermission` before the withdrawal succeeds. New function: `canWithdrawExternal`. New event: `ExternalWithdrawPermissionUpdated`. New error: `ExternalWithdrawNotApproved`.

**Feature 7 — Monthly Receive Limit for Family Transfers**

Family transfers (`isFamilyTransfer = true` in `transferToUser`) are fee-free up to a per-recipient monthly limit. The limit defaults to 5 transfers per 30-day window. Admin can change it with `setFreeReceiveLimit`. The count resets automatically each window (keyed by `block.timestamp / 30 days`). New view: `getMonthlyReceiveCount`.

**Feature 8 — User Tier Classification**

New `UserTier` enum with values `STANDARD`, `SILVER`, `GOLD`, `PLATINUM`. Admin/employees assign tiers with `setUserTier`. Each tier carries a fee discount (in basis points) on the base platform fee, applied only when the merchant has no per-user fee override. Default discounts: SILVER 10%, GOLD 20%, PLATINUM 30% (configurable with `setTierDiscount`). New view: `getUserTier`. New event: `UserTierUpdated`.

**Other changes:**
- VERSION bumped to `1.4.0`

---

### v1.3.0

Three features removed to reduce gas costs and contract complexity:

1. **Open invoice cap system removed** — `setMaxOpenInvoices`, `getOpenInvoiceCount`, the `_openInvoiceCount` mapping, and the `MaxOpenInvoicesReached` error were all removed. The cap was adding gas overhead to every invoice state transition.

2. **`batchCancelInvoices` removed** — Admin/employee bulk cancel function removed. Individual `cancelInvoice` calls remain available.

3. **`withdrawAllTokens` removed** — The convenience sweep function removed. Users continue to use `withdrawETH` and `withdrawToken` for individual withdrawals.

VERSION bumped to `1.3.0`.

---

### v1.2.0

Six security and correctness fixes applied after an internal audit:

**Critical fixes:**

1. **`withdrawToken` — delisted token withdrawal unblocked**
   Removed the `onlySupportedToken` modifier from `withdrawToken`. Previously, if an admin delisted a token, any user holding a balance in that token could not withdraw it — funds were permanently trapped.

2. **`receive()` — pause guard added**
   The fallback function that handles direct ETH sends now checks `paused()` and reverts with `EnforcedPause()` when the contract is paused.

**Medium fixes:**

3. **`adminReleaseToMerchant` / `adminRefundToPayer` — status validation added**
   Both admin escrow functions now require the invoice to be in `PAID` or `DISPUTED` status before proceeding. Previously, calling either function on an invoice with no escrow would silently succeed with zero amounts while incorrectly marking the invoice as `COMPLETED`.

4. **`resolveDispute` — misleading `FundsHeld` event removed**
   After resolving a dispute, the contract was incorrectly emitting a `FundsHeld` event. `FundsHeld` means funds are being frozen, not released. This was causing backend indexers to misread resolved disputes as new freezes.

**Low fixes:**

5. **VERSION bumped to `1.2.0`**

---

### v1.1.0

- Added per-token flat fee support eliminating cross-token decimal mismatch
- Added `ACTIVE` invoice status for mid-stream recurring invoices, preventing merchant self-cancellation after billing starts
- Added `tokenDecimals` registry for frontend/SDK consumers
- Extended `emergencyWithdrawAll` to sweep escrow records in addition to ledger balances
- Added `previewFee(merchant, amount, token)` with correct per-token flat-fee lookup
- `_calculateFee` now accepts `token` parameter for accurate flat-fee resolution
- `removeSupportedToken` now explicitly blocks `address(0)` / ETH
- `setSubscriptionConfig` now validates that the subscription token is whitelisted when fee > 0
- `createInvoice` now rejects self-invoicing (`payer == msg.sender`)

---

## Contract Constants and Key Public Variables

| Name | Type | Value / Default | Description |
|------|------|----------------|-------------|
| `VERSION` | `string constant` | `"1.6.0"` | Deployed contract version |
| `NATIVE_ETH` | `address constant` | `address(0)` | Internal sentinel representing native ETH in the ledger |
| `BPS_DENOMINATOR` | `uint256 constant` | `10_000` | 100% expressed in basis points (100 bps = 1%) |
| `challengeWindowDuration` | `uint256 public` | `30 days` | Payer challenge window after merchant-wins dispute ruling |
| `confirmationWindow` | `uint256 public` | `7 days` | Window for payer to confirm or dispute after merchant calls `markComplete()` |
| `maxChallengesPerInvoice` | `uint256 public` | `1` | Max times a payer may challenge a single dispute ruling |
| `freeReceiveLimit` | `uint256 public` | `5` | Monthly fee-free family transfers per recipient |
| `subscriptionFee` | `uint256 public` | constructor arg | Monthly merchant subscription fee (0 = free) |
| `subscriptionToken` | `address public` | constructor arg | Token used for subscription payments |
| `subscriptionDuration` | `uint256 public` | `30 days` | Subscription validity period after payment |

---

*Contract: `CryptoPaymentPlatform.sol` — Solidity `^0.8.20` — Arbitrum One / Arbitrum Nova*
