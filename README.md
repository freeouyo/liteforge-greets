# LiteForge Greets ⬡

> Daily onchain GM / GN greetings with streak tracking, optional messages and zkLTC tips — built on LitVM, Litecoin's first EVM rollup.

**Live app:** [chaingreets.xyz/liteforge.html](https://chaingreets.xyz/liteforge.html)  
**Hackathon:** [LiteForge Hackathon](https://hackathon.litvm.com) — built by [ChainGreets](https://chaingreets.xyz)

---

## What it does

LiteForge Greets lets anyone send a daily **GM** (Good Morning) or **GN** (Good Night) directly onchain on LitVM Testnet. Each greeting is a real transaction — no backend, no database, no intermediary.

Key features:
- **Onchain streak tracking** — the smart contract stores your consecutive daily streak for GM and GN independently
- **Optional message** — attach up to 280 characters to your greeting, stored onchain in the event log
- **zkLTC tip** — send any amount of zkLTC above the base fee as a tip, held in the contract
- **Live feed** — the last 10 GM/GN events are fetched directly from the chain via `eth_getLogs`
- **One action per day** — enforced at the smart contract level using UTC day index (`block.timestamp / 86400`)

---

## Smart Contract

| Property | Value |
|---|---|
| Contract | `GreetLiteForge.sol` |
| Address | `0xc71677793594e160b6E91540a60A98D7FD0acb7A` |
| Network | LitVM Testnet (Chain ID 4441 / 0x1159) |
| Compiler | Solidity 0.8.34 |
| EVM Version | cancun |
| Optimization | 200 runs |
| Deployer | `0x1A83Af9236DcFFd18007021fC350a585d417D615` |

**Explorer:** [liteforge.explorer.caldera.xyz](https://liteforge.explorer.caldera.xyz/address/0xc71677793594e160b6E91540a60A98D7FD0acb7A)

### Key functions

```solidity
// Send a Good Morning (payable, min 0.000123 zkLTC)
function gm(string calldata message) external payable

// Send a Good Night (payable, min 0.000123 zkLTC)
function gn(string calldata message) external payable

// Read stats for any address
function getStats(address user) external view
  returns (uint256 totalGm, uint256 totalGn, uint256 gmStreak, uint256 gnStreak)

// Check if address can still act today
function canGm(address user) external view returns (bool)
function canGn(address user) external view returns (bool)
```

### Events

```solidity
event GM(address indexed sender, string message, uint256 streak, uint256 tip, uint256 dayIndex)
event GN(address indexed sender, string message, uint256 streak, uint256 tip, uint256 dayIndex)
```

### Security features

- **Reentrancy guard** — custom mutex lock on all state-mutating functions
- **Checks-Effects-Interactions** pattern — state updated before any external call
- **Pause / Unpause** — owner can halt GM/GN in case of emergency
- **Adjustable fee** — owner can update fee within `[0, MAX_FEE]` (capped at 0.01 zkLTC)
- **2-step ownership transfer** — propose + accept prevents accidental transfers
- **MAX_FEE cap** — prevents owner from setting abusive fees

---

## Tech stack

| Layer | Stack |
|---|---|
| Frontend | Vanilla HTML / CSS / JS — no framework, no build step |
| Wallet | EIP-1193 (`eth_requestAccounts`, `wallet_addEthereumChain`) |
| Chain reads | `eth_call` + `eth_getLogs` via RPC — no API key needed |
| Smart contract | Solidity 0.8.34, deployed via Remix IDE |
| Hosting | [Netlify](https://chaingreets.xyz) |

### LitVM / Arbitrum Orbit specifics

LitVM runs on the Arbitrum Nitro/Orbit stack. Two quirks handled in the frontend:

1. **Legacy gas price required** — EIP-1559 not supported. Every transaction injects `gasPrice: 0x989680` (0.1 Gwei).
2. **Nonce from RPC** — the sequencer tracks a `msgIdx`. The pending nonce is always fetched from `eth_getTransactionCount` before signing to avoid `wrong msgIdx` reverts.

---

## Network config

```
Network name : LitVM Testnet
Chain ID     : 4441 (0x1159)
Currency     : zkLTC
RPC          : https://liteforge.rpc.caldera.xyz/http
Explorer     : https://liteforge.explorer.caldera.xyz
```

---

## Repository structure

```
liteforge-greets/
├── index.html          # Frontend — standalone DApp
├── GreetLiteForge.sol  # Smart contract source
└── README.md
```

---

## How to run locally

No build step required. Open `index.html` directly in a browser with a web3 wallet (MetaMask, Rabby, etc.) or serve with any static server:

```bash
python3 -m http.server 8080
# then open http://localhost:8080
```

Make sure your wallet is connected to **LitVM Testnet (Chain ID 4441)**. The app will prompt to add the network automatically if it's not already configured.

---

## Built by

[ChainGreets](https://chaingreets.xyz) — a multi-chain EVM DApp for daily onchain GM/GN greetings across 33+ networks.  
Twitter/X: [@chaingreets](https://x.com/chaingreets)

---

*Submitted to the [LiteForge Hackathon](https://hackathon.litvm.com) — Build Hard Money Web3 on zkLTC.*
