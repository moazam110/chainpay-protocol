# CryptoPaymentPlatform

A production-ready, audited smart contract for crypto invoice payments, escrow, recurring billing, and P2P transfers — deployable on any EVM-compatible chain.

**Current Version:** 1.8.2  
**Solidity:** ^0.8.20  
**Framework:** Foundry  
**License:** MIT  

---

## Overview

CryptoPaymentPlatform is a pool-vault ledger system where all user funds are held inside a single contract. Payments between users are pure ledger updates (no token transfers per payment), making them gas-efficient. Real token transfers only happen on deposit and withdrawal.

### Key Features

| Feature | Description |
|---------|-------------|
| Invoice Payments | PREPAID (escrow) and POSTPAID (instant settle) invoice types |
| Escrow | Funds locked until merchant marks complete and payer confirms |
| Dispute System | Payer can raise disputes; admin resolves; payer can challenge ruling |
| Recurring Billing | Merchant pulls payments on a schedule with payer pre-approval |
| P2P Transfers | Internal ledger transfers with optional fee-free family transfer mode |
| Multi-token | Native ETH/DC + any ERC-20 (USDT, USDC, etc.) |
| Fee Management | Global or per-merchant percentage/flat fees with tier discounts |
| Role System | Admin, Employee, and open merchant/payer roles |
| Emergency Pause | Admin can pause all functions and sweep all funds back to owners |

### Architecture

```
User deposits ERC-20/ETH
        ↓
Internal Ledger (_ledger mapping)
        ↓
Invoice Created → Payer Pays → Funds in Escrow
                                    ↓
              Merchant markComplete() → AWAITING_CONFIRMATION
                                    ↓
              Payer confirmCompletion() → Funds released to merchant
              OR raiseDispute()        → Escrow frozen, admin resolves
              OR timeout expires       → Merchant calls claimPayment()
```

---

## Contract Structure

```
crypto-payment/
├── src/
│   └── CryptoPaymentPlatform.sol   ← main contract (deploy this)
├── script/
│   ├── DeployPlatform.s.sol        ← deploy the platform
│   └── DeployTestToken.s.sol       ← deploy mock USDT/USDC (testnet only)
├── lib/
│   └── openzeppelin-contracts/     ← OZ v5.x dependency
├── out/                            ← compiled ABIs (after forge build)
├── foundry.toml                    ← build config
├── DEPLOYMENT.md                   ← deployed addresses and integration guide
└── COMMANDS.md                     ← full cast command reference
```

---

## Deployed Contracts (Daily Crypto Testnet — Chain 825)

| Contract | Address |
|----------|---------|
| CryptoPaymentPlatform | `0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631` |
| MockUSDT | `0x25D10a10514298bEcbE491c1Ae727FaF2f852538` |
| MockUSDC | `0xAc894b21891EcD48B89eC85b74032b42421c67F8` |

**RPC:** `https://rpc.testnet.dailycrypto.net`  
**Deployer / Admin:** `0x5962e5e56EF6b19b2D7bf4DEc66Ee80088252b6B`

See [DEPLOYMENT.md](DEPLOYMENT.md) for full deployment details, token setup, mainnet guide, and ABI usage.  
See [COMMANDS.md](COMMANDS.md) for every `cast` command to interact with the contract.

---

## Role Hierarchy

```
Admin (owner)
  └─ Full control: fee config, token whitelist, pause, emergency withdraw,
     employee management, ownership transfer

Employee (admin-granted)
  └─ Can resolve disputes, set per-user fees, set user tiers, cancel invoices

Merchant (any wallet)
  └─ Can create invoices, mark work complete, trigger recurring billing

Payer (any wallet)
  └─ Can pay invoices, confirm completion, raise disputes, challenge rulings
```

---

## Invoice Lifecycle

### PREPAID

```
PENDING → (payer pays) → PAID → (merchant markComplete) → AWAITING_CONFIRMATION
    → (payer confirms)          → COMPLETED
    → (payer disputes)          → DISPUTED → (admin resolves) → COMPLETED / CHALLENGE_PENDING
    → (window expires, merchant claims) → COMPLETED
    → (dueDate passes, payer reclaims)  → CANCELLED
```

### POSTPAID

```
PENDING → (payer pays) → COMPLETED   (instant, no escrow)
```

### RECURRING (POSTPAID only)

```
PENDING → (merchant triggers cycle 1) → ACTIVE
        → (merchant triggers cycle 2) → ACTIVE
        → ...
        → (final cycle complete)      → COMPLETED
```

### Invoice Status Values

| Value | Status | Meaning |
|-------|--------|---------|
| 0 | PENDING | Created, awaiting payment |
| 1 | ACTIVE | Recurring: at least 1 cycle done, more remain |
| 2 | PAID | Prepaid: funds in escrow |
| 3 | AWAITING_CONFIRMATION | Merchant submitted work, payer has 7 days |
| 4 | COMPLETED | Settled successfully |
| 5 | CANCELLED | Voided |
| 6 | DISPUTED | Payer raised dispute, escrow frozen |
| 7 | CHALLENGE_PENDING | Admin ruled merchant wins, payer can challenge |

---

## Fee Model

- **Default:** 2.5% (250 basis points) percentage fee on every payment
- **Per-merchant override:** Admin or employee can set a custom percentage or flat fee for any merchant
- **Tier discounts:** SILVER −10%, GOLD −20%, PLATINUM −30% off the base fee
- **P2P transfers:** Always use the global default fee (no tier discounts apply)
- **Fee-free family transfers:** Up to 5 per month if recipient opts the sender in via `approveFamilySender()`

Fee is always deducted at settlement time (not at invoice creation):
- PREPAID: fee taken when payer confirms, merchant claims, or admin releases
- POSTPAID: fee taken instantly on payment
- Recurring: fee taken on each triggered cycle

---

## Security

### Audit Status

Version 1.8.2 has had a full security audit pass. All Critical, High, Medium, and Low findings were addressed:

| Severity | Count | Status |
|----------|-------|--------|
| Critical | 0 | — |
| High | 0 | — |
| Medium | 6 | All fixed |
| Low | 7 | All fixed |
| Informational | 2 | Fixed |

### Key Security Properties

- **Reentrancy:** All state-changing functions use `nonReentrant` + checks-effects-interactions
- **Ownership:** `Ownable2Step` — new owner must actively accept; `renounceOwnership` is disabled
- **Escrow safety:** `released` flag on every escrow record prevents double-release
- **Admin access:** `adminReleaseToMerchant` and `adminRefundToPayer` restricted to `DISPUTED`/`CHALLENGE_PENDING` only
- **Emergency sweep:** Failure-isolated ERC-20 transfers (validates return bool, credits ledger as fallback)
- **Family transfers:** Recipient must explicitly opt sender in via `approveFamilySender()` — no third-party griefing
- **Recurring + PREPAID:** Rejected at invoice creation — prevents ambiguous escrow + pull-payment combination
- **dueDate enforcement:** `markComplete` blocked after dueDate; postpaid payment blocked after dueDate

---

## Quick Start

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### Build

```bash
cd crypto-payment
forge build
```

### Run on testnet (dry run first)

```bash
# Dry run — simulates without broadcasting
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --with-gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Broadcast to deploy
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --with-gas-price 1100000000 \
  --private-key 0xYOUR_KEY --broadcast
```

### Add supported tokens after deploy

```bash
# Native DC is auto-whitelisted in the constructor
# Add USDT
cast send PLATFORM_ADDRESS "addSupportedToken(address,uint8)" USDT_ADDRESS 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 --private-key 0xADMIN_KEY

# Add USDC
cast send PLATFORM_ADDRESS "addSupportedToken(address,uint8)" USDC_ADDRESS 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 --private-key 0xADMIN_KEY
```

---

## Integration

### ABI Location

After `forge build`, the ABI is at:
```
out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json
```

### ethers.js

```js
import { ethers } from "ethers";
import artifact from "./out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json";

const platform = new ethers.Contract(PLATFORM_ADDRESS, artifact.abi, signer);

// Deposit USDT (approve first)
await usdt.approve(PLATFORM_ADDRESS, amount);
await platform.depositToken(USDT_ADDRESS, amount);

// Create a prepaid invoice
await platform.createInvoice(
  payerAddress, tokenAddress, amount, dueDate,
  "Job description", 0, false, 0, 0
);

// Pay a prepaid invoice
await platform.payPrepaidInvoice(invoiceId, deadline);
```

### Key View Functions

```js
await platform.getInvoice(invoiceId)
await platform.balanceOf(userAddress, tokenAddress)
await platform.getEscrow(invoiceId)
await platform.getConfirmationDeadline(invoiceId)
await platform.previewFee(merchantAddress, amount, tokenAddress)
await platform.getMerchantInvoices(merchantAddress)
await platform.getPayerInvoices(payerAddress)
```

### Events to Index

```
InvoiceCreated, InvoicePaid, WorkSubmitted, InvoiceConfirmed,
InvoiceMarkedComplete, FundsReclaimed, DisputeRaised, DisputeResolved,
InvoiceCancelled, RecurringInvoiceTriggered, Deposit, Withdrawal,
P2PTransfer (via InternalTransfer), FeeDeducted
```

---

## Version History

| Version | Summary |
|---------|---------|
| 1.8.2 | Bug fix: native DC (address(0)) now correctly whitelisted in constructor |
| 1.8.1 | Audit follow-up: M-4 residual in adminRefundToPayer closed; N-2 ERC-20 return bool validated in emergency sweep |
| 1.8.0 | Full audit remediation: M-1 through M-6, L-1 through L-7, I-1, I-6 |
| 1.7.0 | Open platform: removed merchant registration and subscription system; constructor simplified to single defaultFeeBps param |
| 1.6.0 | AWAITING_CONFIRMATION status; markComplete/confirmCompletion/claimPayment/reclaimFunds flow; dispute only on AWAITING_CONFIRMATION |
| 1.5.0 | payerAcknowledged flag; challenge cap; calendar month bucket for P2P limits; minimum fee floor |
| 1.4.0 | Partial refund, invoice edit, dispute challenge window, P2P transfer, external wallet, monthly receive limit, user tiers |

---

## Development Notes

- `foundry.toml` sets `evm_version = "paris"` for Daily Crypto testnet (no PUSH0 opcode). Change to `"cancun"` for Ethereum mainnet or Arbitrum.
- Optimizer is enabled (`optimizer = true`, `via_ir = true`, `optimizer_runs = 200`) — required to keep bytecode under the 24 KB EIP-170 limit.
- After any config change, run `forge clean && forge build` to avoid stale cache.
- Native ETH/DC uses `address(0)` as the token sentinel throughout the contract.
