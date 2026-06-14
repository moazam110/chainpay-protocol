# CryptoPaymentPlatform — Deployment Reference

**Version:** 1.8.2  
**Network:** Daily Crypto Testnet  
**Chain ID:** 825  
**RPC:** https://rpc.testnet.dailycrypto.net  
**EVM Version:** Paris  
**Deployer / Admin:** `0x5962e5e56EF6b19b2D7bf4DEc66Ee80088252b6B`  
**Date:** 2026-06-14  

---

## Deployed Contracts

### CryptoPaymentPlatform (main contract)

| Field | Value |
|-------|-------|
| Contract Address | `0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631` |
| Deploy Tx Hash | `0xe3c13ba8d87c64094401d396f141bee9b00afb2aa693433411ecf31cfb7e79ad` |
| Block | 255081 |
| Version | 1.8.2 |
| Default Fee | 250 bps (2.5%) |
| ABI | `out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json` |

### MockUSDT (test token only)

| Field | Value |
|-------|-------|
| Contract Address | `0x25D10a10514298bEcbE491c1Ae727FaF2f852538` |
| Deploy Tx Hash | `0x11a4817abb78970b92d3694c55a35f164b65b85b66637d8fcccd3fd460e52403` |
| Block | 250107 |
| Symbol | USDT |
| Decimals | 6 |
| ABI | `out/DeployTestToken.s.sol/MockUSDT.json` |

### MockUSDC (test token only)

| Field | Value |
|-------|-------|
| Contract Address | `0xAc894b21891EcD48B89eC85b74032b42421c67F8` |
| Deploy Tx Hash | `0xe41e1153ea1042a0a812bdc8fb446eb74233cdb3d42f28376ce5facf8548497a` |
| Block | 250106 |
| Symbol | USDC |
| Decimals | 6 |
| ABI | `out/DeployTestToken.s.sol/MockUSDC.json` |

> MockUSDT and MockUSDC are **testnet-only** fake tokens for development. On mainnet, use real USDT/USDC contract addresses.

---

## Currently Supported Tokens

| Symbol | Address | Decimals | Status |
|--------|---------|----------|--------|
| DC (native) | `0x0000000000000000000000000000000000000000` | 18 | Auto-enabled at deploy |
| USDT | `0x25D10a10514298bEcbE491c1Ae727FaF2f852538` | 6 | Needs `addSupportedToken` call |
| USDC | `0xAc894b21891EcD48B89eC85b74032b42421c67F8` | 6 | Needs `addSupportedToken` call |

> Native DC is automatically whitelisted in the constructor. All ERC-20 tokens must be added by the admin after deployment.

---

## Adding Supported Tokens (Admin Only)

After deploying the platform, the admin must call `addSupportedToken(address token, uint8 decimals)` for each ERC-20 token. Native DC is already enabled automatically.

### Using `cast` (recommended for one-off calls)

```bash
# Add MockUSDT
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "addSupportedToken(address,uint8)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_ADMIN_KEY

# Add MockUSDC
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "addSupportedToken(address,uint8)" \
  0xAc894b21891EcD48B89eC85b74032b42421c67F8 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_ADMIN_KEY
```

### Verify a token is supported

```bash
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "supportedTokens(address)(bool)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  --rpc-url https://rpc.testnet.dailycrypto.net
# Expected: true
```

### Removing a token (disables new invoices, existing balances unaffected)

```bash
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "removeSupportedToken(address)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_ADMIN_KEY
```

> Removing a token does **not** freeze user balances. Users can still withdraw a delisted token via `withdrawToken()`. Only new invoice creation and recurring approvals are blocked.

---

## Mainnet Deployment Guide

### Step 1 — Prepare

1. Fund your deployer wallet with enough native gas token for deployment (~0.05–0.1 ETH on Ethereum mainnet, less on L2s).
2. Have real USDT and USDC contract addresses ready for your target chain.

**Common mainnet token addresses:**

| Chain | USDT | USDC |
|-------|------|------|
| Ethereum | `0xdAC17F958D2ee523a2206206994597C13D831ec7` | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |
| Arbitrum One | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| Base | `0xfde4C96c8593536E31F229EA8f37b2ADa2699bb2` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Polygon | `0xc2132D05D31c914a87C6611C10748AEb04B58e8F` | `0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359` |

### Step 2 — Update `foundry.toml` for target chain

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
evm_version = "paris"   # change to "shanghai" or "cancun" if the chain supports it
optimizer = true
optimizer_runs = 200
via_ir = true
remappings = [
    "@openzeppelin/=lib/openzeppelin-contracts/",
    "forge-std/=lib/forge-std/src/",
]
```

> **EVM version by chain:**
> - Ethereum mainnet, Arbitrum, Base, Polygon → use `"cancun"` or `"shanghai"`
> - Daily Crypto → use `"paris"` (no PUSH0 opcode)

### Step 3 — Dry run

```bash
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url YOUR_MAINNET_RPC \
  --chain-id YOUR_CHAIN_ID \
  --legacy \
  --with-gas-price YOUR_GAS_PRICE \
  --private-key 0xYOUR_KEY
```

Confirm the simulation output shows no size warnings and the estimated gas is reasonable.

### Step 4 — Deploy

```bash
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url YOUR_MAINNET_RPC \
  --chain-id YOUR_CHAIN_ID \
  --legacy \
  --with-gas-price YOUR_GAS_PRICE \
  --private-key 0xYOUR_KEY \
  --broadcast
```

Note the deployed contract address from the output.

### Step 5 — Add supported tokens

```bash
# USDT
cast send PLATFORM_ADDRESS \
  "addSupportedToken(address,uint8)" USDT_ADDRESS 6 \
  --rpc-url YOUR_MAINNET_RPC --chain-id YOUR_CHAIN_ID \
  --legacy --gas-price YOUR_GAS_PRICE --private-key 0xYOUR_KEY

# USDC
cast send PLATFORM_ADDRESS \
  "addSupportedToken(address,uint8)" USDC_ADDRESS 6 \
  --rpc-url YOUR_MAINNET_RPC --chain-id YOUR_CHAIN_ID \
  --legacy --gas-price YOUR_GAS_PRICE --private-key 0xYOUR_KEY
```

### Step 6 — Verify contract (optional but recommended)

```bash
forge verify-contract PLATFORM_ADDRESS \
  src/CryptoPaymentPlatform.sol:CryptoPaymentPlatform \
  --chain YOUR_CHAIN_ID \
  --etherscan-api-key YOUR_ETHERSCAN_KEY \
  --constructor-args $(cast abi-encode "constructor(uint256)" 250)
```

### Mainnet checklist

- [ ] Deployer wallet funded
- [ ] `evm_version` set correctly for target chain
- [ ] Dry run completed with no size warnings
- [ ] Contract deployed and address noted
- [ ] `addSupportedToken` called for USDT and USDC
- [ ] `supportedTokens(USDT)` and `supportedTokens(USDC)` return `true`
- [ ] Contract ownership confirmed: `owner()` returns your admin wallet
- [ ] Contract verified on block explorer (optional)
- [ ] Frontend/backend updated with new contract address and ABI

---

## ABI Guide

### Where to find the ABI

After running `forge build`, ABIs are generated in the `out/` directory:

| Contract | ABI File |
|----------|----------|
| CryptoPaymentPlatform | `out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json` |
| MockUSDT | `out/DeployTestToken.s.sol/MockUSDT.json` |
| MockUSDC | `out/DeployTestToken.s.sol/MockUSDC.json` |

The full JSON file contains the ABI under the `"abi"` key. Extract it for frontend use:

```bash
cat out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json | python3 -c \
  "import sys,json; print(json.dumps(json.load(sys.stdin)['abi'], indent=2))" \
  > abi/CryptoPaymentPlatform.abi.json
```

### Using the ABI in ethers.js (frontend)

```js
import { ethers } from "ethers";
import platformAbi from "./abi/CryptoPaymentPlatform.abi.json";

const PLATFORM_ADDRESS = "0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631";

const provider = new ethers.BrowserProvider(window.ethereum);
const signer   = await provider.getSigner();
const platform = new ethers.Contract(PLATFORM_ADDRESS, platformAbi, signer);

// Example: create an invoice
const tx = await platform.createInvoice(
  payerAddress,         // payer
  usdtAddress,          // token (or address(0) for native DC)
  ethers.parseUnits("100", 6),  // amount — 100 USDT
  Math.floor(Date.now() / 1000) + 7 * 86400,  // dueDate — 7 days from now
  "Website redesign",   // description
  0,                    // PaymentType.PREPAID
  false,                // isRecurring
  0,                    // recurringInterval
  0                     // maxCycles
);
await tx.wait();
```

### Using the ABI in web3.py (backend / indexer)

```python
from web3 import Web3
import json

w3 = Web3(Web3.HTTPProvider("https://rpc.testnet.dailycrypto.net"))

with open("out/CryptoPaymentPlatform.sol/CryptoPaymentPlatform.json") as f:
    artifact = json.load(f)

platform = w3.eth.contract(
    address=Web3.to_checksum_address("0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631"),
    abi=artifact["abi"]
)

# Example: read an invoice
invoice = platform.functions.getInvoice(1).call()
print(invoice)

# Example: listen for InvoiceCreated events
event_filter = platform.events.InvoiceCreated.create_filter(from_block="latest")
```

---

## Frontend Integration Notes

### ERC-20 Approval (required before paying)

Before calling `payPrepaidInvoice` or `payPostpaidInvoice`, the payer must approve the platform to spend their tokens:

```js
const usdt = new ethers.Contract(usdtAddress, erc20Abi, signer);
await usdt.approve(PLATFORM_ADDRESS, amount);  // then call payPrepaidInvoice
```

For native DC payments, no approval is needed — send `value` with the transaction and pass `address(0)` as the token field.

### Invoice Status Enum

```
0 — PENDING               created, not yet paid
1 — ACTIVE                recurring: ≥1 cycle done, more remain
2 — PAID                  prepaid: funds in escrow, awaiting merchant
3 — AWAITING_CONFIRMATION merchant submitted work, payer has 7 days to confirm or dispute
4 — COMPLETED             settled successfully
5 — CANCELLED             voided (by merchant, payer, or admin)
6 — DISPUTED              payer raised a dispute, escrow frozen
7 — CHALLENGE_PENDING     admin ruled merchant wins, payer has challenge window
```

### Payment Type Enum

```
0 — PREPAID    payer pays first, funds held in escrow until merchant completes
1 — POSTPAID   merchant works first, payer pays on receipt (instant settle)
```

### Key View Functions

```solidity
getInvoice(uint256 invoiceId)                          // full invoice struct
getEscrow(uint256 invoiceId)                           // escrow status for prepaid
getConfirmationDeadline(uint256 invoiceId)             // payer confirmation deadline
getChallengeDeadline(uint256 invoiceId)                // payer challenge deadline after dispute ruling
getMerchantInvoices(address merchant)                  // all invoice IDs for a merchant
getPayerInvoices(address payer)                        // all invoice IDs for a payer
balanceOf(address user, address token)                 // internal ledger balance
getRecurringApproval(address payer, address merchant, address token)
previewFee(address merchant, uint256 amount, address token)  // simulate fee split
getTokenInfo(address token)                            // supported + decimals
getEffectiveFee(address merchant)                      // merchant's active fee tier
```

---

## Backend / Indexer — Events to Listen

```solidity
InvoiceCreated(uint256 indexed invoiceId, address indexed merchant, address indexed payer, uint256 amount, address token, PaymentType paymentType, bool isRecurring)
InvoicePaid(uint256 indexed invoiceId, address indexed payer, uint256 amount, uint256 timestamp)
WorkSubmitted(uint256 indexed invoiceId, address indexed merchant)
InvoiceConfirmed(uint256 indexed invoiceId, address indexed payer)
InvoiceMarkedComplete(uint256 indexed invoiceId, address indexed merchant)
FundsReclaimed(uint256 indexed invoiceId, address indexed payer)
DisputeRaised(uint256 indexed invoiceId, address indexed payer, string reason)
DisputeResolved(uint256 indexed invoiceId, string decision, address indexed resolver)
InvoiceCancelled(uint256 indexed invoiceId, string reason)
InvoiceAcknowledged(uint256 indexed invoiceId, address indexed payer)
InvoiceEdited(uint256 indexed invoiceId, address indexed editor, uint256 timestamp)
RecurringInvoiceTriggered(uint256 indexed invoiceId, uint256 cycleNumber)
P2PTransfer(address indexed from, address indexed to, address indexed token, uint256 amount)
FeeDeducted(uint256 indexed invoiceId, uint256 feeAmount, address token)
Deposit(address indexed user, address indexed token, uint256 amount)
Withdrawal(address indexed user, address indexed token, uint256 amount)
TokenAdded(address indexed token, uint8 decimals)
TokenRemoved(address indexed token)
AdminTransferred(address indexed oldAdmin, address indexed newAdmin)
```

### Key Constants

| Name | Value |
|------|-------|
| Fee denominator | 10,000 (basis points) |
| Default platform fee | 250 bps = 2.5% |
| Confirmation window | 7 days (604,800 seconds) |
| Challenge window | 30 days (2,592,000 seconds) |
| Native token sentinel | `0x0000000000000000000000000000000000000000` |
| Max challenges per invoice | 1 (admin-configurable) |

---

## Deploy Commands Reference

### Testnet (Daily Crypto — chain 825)

```bash
# Dry run
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --with-gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Broadcast
forge script script/DeployPlatform.s.sol:DeployPlatform \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --with-gas-price 1100000000 \
  --private-key 0xYOUR_KEY --broadcast
```

### Check contract version on-chain

```bash
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "VERSION()(string)" \
  --rpc-url https://rpc.testnet.dailycrypto.net
# Expected: "1.8.2"
```

### Check admin wallet

```bash
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "owner()(address)" \
  --rpc-url https://rpc.testnet.dailycrypto.net
```
