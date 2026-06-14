# CryptoPaymentPlatform — Command Reference

All commands use `cast` from the Foundry toolkit.

**Contract addresses (Daily Crypto Testnet — chain 825):**

| Contract | Address |
|----------|---------|
| CryptoPaymentPlatform | `0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631` |
| MockUSDT | `0x25D10a10514298bEcbE491c1Ae727FaF2f852538` |
| MockUSDC | `0xAc894b21891EcD48B89eC85b74032b42421c67F8` |

**Shorthand used throughout this file:**

```
PLATFORM  = 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631
USDT      = 0x25D10a10514298bEcbE491c1Ae727FaF2f852538
USDC      = 0xAc894b21891EcD48B89eC85b74032b42421c67F8
RPC       = https://rpc.testnet.dailycrypto.net
CHAIN     = 825
GAS_PRICE = 1100000000
```

**Execute command base flags** (append `--private-key 0xYOUR_KEY` to all write commands):
```
--rpc-url https://rpc.testnet.dailycrypto.net --chain-id 825 --legacy --gas-price 1100000000
```

---

## 1. Wallet & Token Balance Checks

```bash
# Native DC balance of any wallet
cast balance 0xWALLET_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# MockUSDT balance of any wallet
cast call 0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  "balanceOf(address)(uint256)" 0xWALLET_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# MockUSDC balance of any wallet
cast call 0xAc894b21891EcD48B89eC85b74032b42421c67F8 \
  "balanceOf(address)(uint256)" 0xWALLET_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Internal ledger balance inside the platform (any token)
# Use address(0) = 0x0000000000000000000000000000000000000000 for native DC
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "balanceOf(address,address)(uint256)" 0xUSER_ADDRESS 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check token allowance (how much a wallet approved the platform to spend)
cast call 0xTOKEN_ADDRESS \
  "allowance(address,address)(uint256)" 0xOWNER 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

---

## 2. ERC-20 Token Transfers (wallet to wallet)

```bash
# Transfer USDT to another wallet
# Amount in base units: 1 USDT = 1000000 (6 decimals)
cast send 0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  "transfer(address,uint256)" 0xRECIPIENT 1000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Transfer USDC to another wallet
cast send 0xAc894b21891EcD48B89eC85b74032b42421c67F8 \
  "transfer(address,uint256)" 0xRECIPIENT 1000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

---

## 3. Deposits into Platform

Deposits move funds from your wallet into the platform's internal ledger.

```bash
# Step 1 — Approve platform to spend your USDT (do this once per token)
cast send 0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  "approve(address,uint256)" \
  0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 999999999999999 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Step 2 — Deposit USDT into platform (e.g. 100 USDT = 100000000)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "depositToken(address,uint256)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 100000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Deposit native DC (send value directly — no approve needed)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "depositETH()" \
  --value 1000000000000000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

---

## 4. Withdrawals from Platform

Withdrawals move funds from the platform's internal ledger back to your wallet.

```bash
# Withdraw USDT (e.g. 50 USDT = 50000000)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "withdrawToken(address,uint256)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 50000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Withdraw native DC (e.g. 1 DC = 1000000000000000000 wei)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "withdrawETH(uint256)" 1000000000000000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

---

## 5. Invoice Management

### Create Invoice

```bash
# Arguments:
#   payer             address
#   token             address  (use 0x000...000 for native DC)
#   amount            uint256  (base units)
#   dueDate           uint256  (unix timestamp)
#   description       string
#   paymentType       uint8    (0=PREPAID, 1=POSTPAID)
#   isRecurring       bool
#   recurringInterval uint256  (seconds, 0 if not recurring)
#   maxCycles         uint256  (0 if not recurring)

# Example: PREPAID invoice for 100 USDT, due in 7 days
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "createInvoice(address,address,uint256,uint256,string,uint8,bool,uint256,uint256)" \
  0xPAYER_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  100000000 \
  $(( $(date +%s) + 604800 )) \
  "Website redesign" \
  0 false 0 0 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Example: POSTPAID invoice for 50 USDC
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "createInvoice(address,address,uint256,uint256,string,uint8,bool,uint256,uint256)" \
  0xPAYER_ADDRESS \
  0xAc894b21891EcD48B89eC85b74032b42421c67F8 \
  50000000 \
  $(( $(date +%s) + 604800 )) \
  "Logo design" \
  1 false 0 0 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Example: Recurring POSTPAID invoice — 10 USDT/month for 6 months
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "createInvoice(address,address,uint256,uint256,string,uint8,bool,uint256,uint256)" \
  0xPAYER_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  10000000 \
  $(( $(date +%s) + 15897600 )) \
  "Monthly retainer" \
  1 true 2592000 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

### Cancel Invoice (merchant — PENDING only)

```bash
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "cancelInvoice(uint256,string)" 1 "Client requested cancellation" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

### Reject Invoice (payer — PENDING only)

```bash
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "rejectInvoice(uint256,string)" 1 "Price too high" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

### Edit Invoice (merchant — PENDING only)

```bash
# Pass 0 / "" for fields you don't want to change
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "editInvoice(uint256,uint256,uint256,string,uint256,uint256)" \
  1 \
  120000000 \
  $(( $(date +%s) + 1209600 )) \
  "Updated description" \
  0 0 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

### Acknowledge Invoice (payer — required after edit)

```bash
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "acknowledgeInvoice(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY
```

---

## 6. Prepaid Payment Flow

```bash
# Step 1 — Payer pays (locks funds in escrow)
# deadline = unix timestamp after which this call expires (protect against stale txs)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "payPrepaidInvoice(uint256,uint256)" \
  1 $(( $(date +%s) + 3600 )) \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Step 2 — Merchant marks work complete (starts 7-day confirmation window)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "markComplete(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xMERCHANT_KEY

# Step 3a — Payer confirms (releases escrow to merchant)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "confirmCompletion(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Step 3b — Payer disputes (freezes escrow, opens dispute)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "raiseDispute(uint256,string)" 1 "Work was not delivered as agreed" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Step 3c — Merchant claims payment after confirmation window expires
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "claimPayment(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xMERCHANT_KEY

# Payer reclaims funds if merchant never called markComplete and dueDate passed
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "reclaimFunds(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY
```

---

## 7. Postpaid Payment Flow

```bash
# Payer settles in one step (no escrow — instant release to merchant)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "payPostpaidInvoice(uint256,uint256)" \
  1 $(( $(date +%s) + 3600 )) \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY
```

---

## 8. Recurring Payments

```bash
# Payer approves merchant to pull recurring payments
# maxPerCycle: max per single pull | totalLimit: 0 = unlimited
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "approveRecurring(address,address,uint256,uint256)" \
  0xMERCHANT_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  10000000 \
  60000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Merchant triggers the next billing cycle
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "triggerRecurring(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xMERCHANT_KEY

# Payer revokes a recurring approval
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "revokeRecurring(address,address)" \
  0xMERCHANT_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Check recurring approval details
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getRecurringApproval(address,address,address)(bool,uint256,uint256,uint256,uint256)" \
  0xPAYER_ADDRESS 0xMERCHANT_ADDRESS 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

---

## 9. Dispute System

```bash
# Admin/employee resolves a dispute
# releaseToMerchant: true = merchant wins | false = refund payer
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "resolveDispute(uint256,bool,string)" \
  1 true "Work was delivered and verified" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Payer challenges a merchant-wins ruling (within challenge window)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "challengeDispute(uint256,string)" \
  1 "I have screenshots proving non-delivery" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xPAYER_KEY

# Anyone finalizes a merchant-wins ruling after challenge window expires
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "finalizeResolution(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Admin force-releases escrow to merchant (DISPUTED or CHALLENGE_PENDING only)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "adminReleaseToMerchant(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Admin partially or fully refunds payer (DISPUTED or CHALLENGE_PENDING only)
# refundAmount = full escrow for full refund, less for partial
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "adminRefundToPayer(uint256,uint256)" 1 100000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

---

## 10. P2P Internal Transfer

```bash
# Transfer to another user inside the platform (fee applies)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "transferToUser(address,address,uint256,bool)" \
  0xRECIPIENT_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  50000000 \
  false \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Family transfer (fee-free up to monthly limit — recipient must approve sender first)
# Step 1 — Recipient approves sender as family
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "approveFamilySender(address,bool)" \
  0xSENDER_ADDRESS true \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xRECIPIENT_KEY

# Step 2 — Sender does the transfer with isFamilyTransfer = true
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "transferToUser(address,address,uint256,bool)" \
  0xRECIPIENT_ADDRESS \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 \
  50000000 \
  true \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xSENDER_KEY

# Revoke family approval
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "approveFamilySender(address,bool)" \
  0xSENDER_ADDRESS false \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xRECIPIENT_KEY

# Check monthly receive count for a user
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getMonthlyReceiveCount(address)(uint256)" 0xUSER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

---

## 11. External Wallet Registration

```bash
# Register an external wallet (blocks withdrawals until admin grants permission)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "registerExternalWallet(address)" 0xEXTERNAL_WALLET \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Remove external wallet (restores normal withdrawal access)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "removeExternalWallet()" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xYOUR_KEY

# Check which external wallet is registered for a user
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getExternalWallet(address)(address)" 0xUSER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check if a user has external withdrawal permission
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "canWithdrawExternal(address)(bool)" 0xUSER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

---

## 12. Query / View Functions

```bash
# Get full invoice details
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getInvoice(uint256)((uint256,address,address,address,uint256,uint256,string,uint8,uint8,bool,uint256,uint256,uint256,uint256,uint256,bool))" \
  1 --rpc-url https://rpc.testnet.dailycrypto.net

# Get escrow status for a prepaid invoice
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getEscrow(uint256)(address,uint256,bool,bool)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get confirmation deadline (timestamp payer must confirm/dispute by)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getConfirmationDeadline(uint256)(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get challenge deadline (timestamp payer can challenge ruling until)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getChallengeDeadline(uint256)(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get all invoice IDs created by a merchant
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getMerchantInvoices(address)(uint256[])" 0xMERCHANT_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get all invoice IDs assigned to a payer
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getPayerInvoices(address)(uint256[])" 0xPAYER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get total number of invoices ever created
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "totalInvoices()(uint256)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Preview fee split before paying (returns fee and net amount)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "previewFee(address,uint256,address)(uint256,uint256)" \
  0xMERCHANT_ADDRESS 100000000 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get effective fee config for a merchant
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getEffectiveFee(address)(uint8,uint256,bool)" 0xMERCHANT_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get effective flat fee for a merchant-token pair
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getEffectiveFlatFee(address,address)(uint256)" \
  0xMERCHANT_ADDRESS 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get token whitelist status and decimals
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getTokenInfo(address)(bool,uint8)" 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get user config (employee flag)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getUserConfig(address)((bool))" 0xUSER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get user loyalty tier (0=STANDARD 1=SILVER 2=GOLD 3=PLATINUM)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getUserTier(address)(uint8)" 0xUSER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check if an address is an employee
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "isEmployee(address)(bool)" 0xADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check contract version
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "VERSION()(string)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check contract owner (admin)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "owner()(address)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check if contract is paused
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "paused()(bool)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Check if a family sender is approved
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "familyApproved(address,address)(bool)" \
  0xRECIPIENT 0xSENDER \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get all merchants a payer has ever approved for recurring
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "getPayerApprovedMerchants(address)(address[])" 0xPAYER_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get confirmation window duration (seconds)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "confirmationWindow()(uint256)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get challenge window duration (seconds)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "challengeWindowDuration()(uint256)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get free receive limit (monthly family transfer cap)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "freeReceiveLimit()(uint256)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get max challenges allowed per invoice
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "maxChallengesPerInvoice()(uint256)" \
  --rpc-url https://rpc.testnet.dailycrypto.net

# Get default fee config (feeType: 0=PERCENTAGE 1=FLAT, value in bps)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "defaultFeeConfig()((uint8,uint256,bool))" \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

---

## 13. Admin Config Commands

### Token Management

```bash
# Add a supported token
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "addSupportedToken(address,uint8)" 0xTOKEN_ADDRESS 6 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Remove a supported token (user balances unaffected)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "removeSupportedToken(address)" 0xTOKEN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### Fee Management

```bash
# Set global percentage fee (250 = 2.5%)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setDefaultFee(uint8,uint256)" 0 250 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set global flat fee for a specific token (e.g. 1 USDT = 1000000)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setDefaultFlatFee(address,uint256)" \
  0x25D10a10514298bEcbE491c1Ae727FaF2f852538 1000000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set custom percentage fee for a specific merchant (100 = 1%)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setUserFee(address,uint8,uint256)" 0xMERCHANT_ADDRESS 0 100 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set flat fee override for a merchant on a specific token
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setUserFlatFee(address,address,uint256)" \
  0xMERCHANT_ADDRESS 0xTOKEN_ADDRESS 500000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Remove a merchant's custom fee (reverts to global default)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "removeUserFee(address)" 0xMERCHANT_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### Employee Management

```bash
# Grant employee role
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "addEmployee(address)" 0xEMPLOYEE_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Revoke employee role
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "removeEmployee(address)" 0xEMPLOYEE_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### User Tier Management

```bash
# Set user tier (0=STANDARD 1=SILVER 2=GOLD 3=PLATINUM)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setUserTier(address,uint8)" 0xUSER_ADDRESS 2 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set fee discount for a tier (2000 = 20% off the platform fee)
# tier: 0=STANDARD 1=SILVER 2=GOLD 3=PLATINUM
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setTierDiscount(uint8,uint256)" 2 2000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### Window & Limit Config

```bash
# Set confirmation window (min 1 day = 86400 seconds)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setConfirmationWindow(uint256)" 604800 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set challenge window (min 1 day = 86400 seconds)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setChallengeWindow(uint256)" 2592000 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set max challenges per invoice
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setMaxChallenges(uint256)" 1 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Set monthly free family transfer receive limit
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setFreeReceiveLimit(uint256)" 5 \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### External Withdrawal Permission

```bash
# Grant or revoke external withdrawal permission for a user
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "setExternalWithdrawPermission(address,bool)" 0xUSER_ADDRESS true \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

### Ownership Transfer (2-step)

```bash
# Step 1 — Current admin proposes new owner
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "transferOwnership(address)" 0xNEW_ADMIN_ADDRESS \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xCURRENT_ADMIN_KEY

# Step 2 — New owner accepts (must be called from the new admin wallet)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "acceptOwnership()" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xNEW_ADMIN_KEY

# Check pending owner (before they accept)
cast call 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "pendingOwner()(address)" \
  --rpc-url https://rpc.testnet.dailycrypto.net
```

### Pause / Unpause

```bash
# Pause all contract functions (emergency only)
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "pause()" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY

# Unpause
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "unpause()" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

---

## 14. Emergency Withdrawal (Admin — Paused Only)

Only callable when the contract is paused. Sweeps all user ledger balances and unreleased escrow back to their owners.

```bash
cast send 0xC93ABa2273C47e0f8298FD49Cd193B8B045cD631 \
  "emergencyWithdrawAll(address[],address[],uint256[])" \
  "[0xUSER1,0xUSER2]" \
  "[0x0000000000000000000000000000000000000000,0x25D10a10514298bEcbE491c1Ae727FaF2f852538]" \
  "[1,2,3]" \
  --rpc-url https://rpc.testnet.dailycrypto.net \
  --chain-id 825 --legacy --gas-price 1100000000 \
  --private-key 0xADMIN_KEY
```

---

## Quick Reference — Amount Conversion

| Human amount | Base units (USDT/USDC, 6 decimals) |
|-------------|-----------------------------------|
| 1 token | `1000000` |
| 10 tokens | `10000000` |
| 100 tokens | `100000000` |
| 500 tokens | `500000000` |
| 1,000 tokens | `1000000000` |
| 500,000 tokens | `500000000000` |
| 1,000,000 tokens | `1000000000000` |

| Human amount | Base units (DC/ETH, 18 decimals) |
|-------------|----------------------------------|
| 0.001 DC | `1000000000000000` |
| 0.01 DC | `10000000000000000` |
| 0.1 DC | `100000000000000000` |
| 1 DC | `1000000000000000000` |
| 10 DC | `10000000000000000000` |

**Get current unix timestamp:**
```bash
date +%s
```
