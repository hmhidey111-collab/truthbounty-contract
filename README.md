# 📜 TruthBounty Smart Contracts


**On-chain Incentives & Verification Logic**  
*Smart contracts powering decentralized truth verification across Ethereum and Stellar*

![License](https://img.shields.io/badge/license-MIT-green)
![Solidity](https://img.shields.io/badge/solidity-%5E0.8.x-blue)
![Status](https://img.shields.io/badge/status-active%20development-blue)

---

## 🌍 Overview

This repository contains the **smart contracts** that power TruthBounty’s decentralized verification and incentive mechanisms.

The contracts handle:
- Verifier staking
- Reward distribution
- Reputation-weighted participation
- Transparent, auditable verification outcomes

TruthBounty contracts are designed as **public-good primitives**, enabling trust-minimized fact verification at scale.

---

## 🌱 Ecosystem Alignment

TruthBounty contracts are aligned with:

- **Ethereum** – secure, neutral settlement layer  
- **Optimism** – low-cost reward distribution  
- **Stellar (planned)** – micro-rewards & global accessibility  
- **Public Goods Funding** – long-term sustainability via Drips  

Contracts are intentionally modular to support **multi-chain deployments**.

---

## 🔗 Contract Responsibilities

## Security & Release Framework

The protocol release process is documented in:

- docs/verification/formal-verification-plan.md
- docs/verification/protocol-invariants.md
- docs/audit/audit-readiness-checklist.md
- docs/release/release-candidate-process.md
- docs/release/mainnet-readiness-scorecard.md
- docs/runbooks/
- [docs/storage-layout-compatibility.md](docs/storage-layout-compatibility.md) — automated upgradeable storage layout gate (V2-SC-046)

### Core Modules

- **Verifier Staking**
  - Users stake tokens to participate in verification
  - Stake size influences verification weight

- **Reward Distribution**
  - ERC-20 rewards issued based on consensus outcomes
  - Slashing for malicious or incorrect verification

- **Reputation Hooks**
  - Reputation updates triggered by verification results
  - Designed to integrate with off-chain scoring engines

---

## 🌟 Stellar Compatibility (Planned)

TruthBounty smart contracts are designed with **Soroban compatibility** in mind.

### Planned Integrations
- Soroban-based reward settlement
- Stellar-native verifier incentives
- Cross-chain verification proofs (Ethereum ↔ Stellar)
- Low-fee micro-rewards for emerging markets

TruthBounty treats smart contracts as **portable logic**, not ecosystem lock-in.

---

## ⚙️ Tech Stack

| Technology | Purpose |
|---------|--------|
| Solidity | Ethereum smart contracts |
| Optimism | L2 deployment |
| Hardhat / Foundry | Development & testing |
| Ethers.js | Contract interaction |
| Soroban (planned) | Stellar smart contracts |

---

## 🛠️ Development Setup

### Environment Variables

Copy `.env.example` to `.env` and fill in the required values:

```
PRIVATE_KEY=your_private_key_here
OPTIMISM_SEPOLIA_RPC_URL=https://sepolia.optimism.io
OPTIMISM_SEPOLIA_GAS_PRICE=10000000
OPTIMISM_MAINNET_RPC_URL=https://mainnet.optimism.io
OPTIMISM_MAINNET_GAS_PRICE=10000000
OPTIMISM_ETHERSCAN_API_KEY=your_optimism_etherscan_api_key
```

**Notes:**
- Never commit your real private key.
- Gas price can be omitted for auto, or set for custom deployments.
- Use the correct RPC endpoints for your provider (Infura, Alchemy, etc).


### Prerequisites

- Node.js v20 LTS or v22 LTS (`>=20.0.0`, enforced via `engines` in `package.json`)
- npm v10+ (required — this repository is npm-managed; no lockfile is maintained for yarn/pnpm)
- Git

### Toolchain note (Hardhat 2 baseline)

This repository is standardized on the **Hardhat 2** toolchain (Hardhat `2.29.1` with matching plugin majors). A migration to **Hardhat 3 is explicitly out of scope** and must be proposed as a separate, individually approved epic — do not bundle it into other work. When bumping dependencies, keep every plugin inside its Hardhat 2 peer range (e.g. `@nomicfoundation/hardhat-ethers` 3.x, `@typechain/hardhat` 9.x, `typechain` 8.x, `chai` 4.x); `hardhat-toolbox@6.1.2` pins the compatible set.

---

### Installation

```bash
git clone https://github.com/DigiNodes/truthbounty-contract.git
cd truthbounty-contract

npm install
```

---

## 📜 Interactive Scripts

The repository includes helper scripts to interact with deployed TruthBounty contracts.

### 🔧 Configuration

Before running scripts, set the required environment variables:

```bash
# Contract addresses (update with your deployed addresses)
export TRUTH_BOUNTY_TOKEN_ADDRESS=0x...
export TRUTH_BOUNTY_CONTRACT_ADDRESS=0x...

# Optional: Custom amounts
export AMOUNT=1000
export CLAIM_ID=1
```

Or create a `.env` file:

```bash
TRUTH_BOUNTY_TOKEN_ADDRESS=0x...
TRUTH_BOUNTY_CONTRACT_ADDRESS=0x...
AMOUNT=1000
CLAIM_ID=1
```

---

### 💰 Staking Tokens

Stake BOUNTY tokens to participate in verification:

```bash
# Default amount (100 BOUNTY)
npx hardhat run scripts/stake.ts --network optimism_sepolia

# Custom amount
AMOUNT=1000 npx hardhat run scripts/stake.ts --network optimism_sepolia

# Using .env file
npx hardhat run scripts/stake.ts --network optimism_sepolia
```

**What it does:**
- Checks your BOUNTY token balance
- Approves token transfer
- Stakes tokens into the TruthBounty protocol
- Displays your current stake information

---

### 🗳️ Creating & Voting on Claims

To create a claim and vote, you'll need to interact directly with the contract:

```typescript
// Example using ethers.js
const truthBounty = await ethers.getContractAt("TruthBounty", TRUTH_BOUNTY_CONTRACT_ADDRESS);

// Create a claim
const tx = await truthBounty.createClaim("IPFS_hash_or_content_reference");
await tx.wait();

// Vote on a claim
const voteTx = await truthBounty.vote(
  claimId,      // Claim ID
  true,         // true = pass, false = fail
  stakeAmount   // Amount in wei (minimum: 100 BOUNTY)
);
await voteTx.wait();
```

---

### ⚖️  Settling Claims

Settle a claim after the verification window closes (7 days):

```bash
# Settle claim with ID 1
CLAIM_ID=1 npx hardhat run scripts/resolveClaim.ts --network optimism_sepolia

# With custom contract address
TRUTH_BOUNTY_CONTRACT_ADDRESS=0x... CLAIM_ID=1 npx hardhat run scripts/resolveClaim.ts --network optimism_sepolia
```

**What it does:**
- Checks if the verification window has closed
- Verifies that votes have been cast
- Predicts the outcome based on votes (60% threshold to pass)
- Settles the claim and calculates rewards/slashes
- Displays settlement results

**Preconditions:**
- The verification window must be closed (7 days from creation)
- At least one vote must have been cast
- Claim must not already be settled

---

### 🎁 Claiming Rewards

Claim your rewards after a claim is settled:

```bash
# Claim rewards for claim ID 1
CLAIM_ID=1 npx hardhat run scripts/claimRewards.ts --network optimism_sepolia

# With custom contract address
TRUTH_BOUNTY_CONTRACT_ADDRESS=0x... CLAIM_ID=1 npx hardhat run scripts/claimRewards.ts --network optimism_sepolia
```

**What it does:**
- Verifies you voted on the claim
- Checks if you're on the winning side
- Claims both rewards and your staked tokens
- Displays updated vote status

**Preconditions:**
- You must have voted on the claim
- The claim must be settled
- You must be on the winning side (voted with the majority)
- Rewards must not already be claimed

**Note:** Only verifiers who voted on the winning side receive rewards. Losers get slashed.

---

### ✅ Verifying Contracts

Verify deployed contracts on block explorers:

```bash
# Verify a single contract
npx hardhat run scripts/verify.ts --network optimism_sepolia --address 0x...

# Verify with constructor arguments
npx hardhat run scripts/verify.ts --network optimism --address 0x... --constructor-args "0x...,0x..."

# Batch verify from deployment file
npx hardhat run scripts/verify.ts --network optimism_sepolia --deployment deployment-addresses.json
```

For more options, see `scripts/verify.ts` or run with `--help`.

---

### 📝 Script Reference

| Script | Purpose | Required Env Vars | Optional Env Vars |
|--------|---------|-------------------|-------------------|
| `stake.ts` | Stake BOUNTY tokens | `TRUTH_BOUNTY_TOKEN_ADDRESS` | `AMOUNT` |
| `resolveClaim.ts` | Settle a claim | `TRUTH_BOUNTY_CONTRACT_ADDRESS`, `CLAIM_ID` | - |
| `claimRewards.ts` | Claim rewards | `TRUTH_BOUNTY_CONTRACT_ADDRESS`, `CLAIM_ID` | - |
| `verify.ts` | Verify contracts | `--address` flag | `--constructor-args`, `--contract` |

---

### 🔍 Common Issues

**"Insufficient token balance"**
- Make sure you have enough BOUNTY tokens in your wallet
- Check that you've approved the contract to spend your tokens

**"Verification window not closed"**
- Wait for the 7-day verification period to end
- Use `resolveClaim.ts` to check the timing

**"Not a winner"**
- You voted on the losing side of the claim
- Unfortunately, you're not eligible for rewards and will be slashed

**"Rewards already claimed"**
- You can only claim rewards once per claim
- Check your vote status in the script output

**"Claim already settled"**
- The claim has already been resolved
- Proceed to claim your rewards using `claimRewards.ts`


## 👥 Contributing

We welcome:

- Smart contract engineers
- Security researchers
- Auditors
- Protocol designers


test
test
test
