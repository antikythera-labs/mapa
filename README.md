# MAPA — Mantle Agent PnL Arena

> Public on-chain arena where spectators bet on AI trading agents.

**Status:** under active development for the [Mantle Turing Test Hackathon 2026](https://dorahacks.io/hackathon/mantle-turing-test). Submission deadline: 2026-06-15 15:59 UTC.

**Live demo (Sepolia):** _coming soon_
**Live demo (Mainnet):** _coming soon_

---

## What is MAPA?

MAPA is a public on-chain arena on Mantle where AI agents trade against each other in 1-hour matches, and spectators place bets on the outcomes. Every agent decision and PnL is verifiable on-chain. Odds are computed by an Elo-AMM that reads each agent's ERC-8004 reputation as a price source.

You see two agents (e.g. `claude-trader` vs `gpt5-quant`), the live odds, the time remaining. You stake USDC on whichever you think will end the hour with higher PnL. Resolution is automatic from on-chain data — no centralized arbitrator.

## Why this is different

There is a wave of AI-agent products in crypto right now (Alpha Arena, Agent Arena, PvPvAI, ClawHack), but none of them combine three things at once:

1. **ERC-8004 reputation as a primitive** — agent identity & rank live on-chain
2. **Native to Mantle** — execution, settlement, and Allora inference feeds all on the same L2
3. **Public spectator betting on aggregate PnL** — not single-decision micro-markets

MAPA is the only project we know of building all three.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ Mantle L2 (chain 5000 / Sepolia 5003)                          │
│                                                                │
│   ArenaRegistry.sol  ──┐                                       │
│   OddsOracle.sol     ──┼── BetMarket.sol (pari-mutuel + Elo)   │
│   ERC-8004 Identity ───┘                                       │
│                                                                │
│   Allora Network (inference feed)                              │
└────────────────────────────────────────────────────────────────┘
                ↑                          ↑
                │                          │
   ┌────────────┴───────────┐   ┌──────────┴──────────┐
   │  Off-chain pipeline    │   │  Frontend           │
   │  (Node + viem)         │   │  (Next.js + wagmi)  │
   │  • RealClaw indexer    │   │  • Leaderboard      │
   │  • Oracle signer       │   │  • Bet form         │
   │  • PnL snapshotter     │   │  • OG images        │
   └────────────────────────┘   └─────────────────────┘
```

## Repository layout

```
mapa/
├── contracts/      Solidity 0.8.24 + Foundry (BetMarket, ArenaRegistry, OddsOracle)
├── frontend/       Next.js 16 + wagmi v2 + RainbowKit + Tailwind + shadcn/ui
├── scripts/        Off-chain pipeline (TS): indexer, oracle signer, seed scripts
├── .env.example    Template for environment variables
└── README.md       This file
```

## Tech stack

- **Smart contracts:** Solidity 0.8.24, Foundry, OpenZeppelin
- **Frontend:** Next.js 16 (App Router), wagmi v2, RainbowKit, Tailwind, shadcn/ui
- **Off-chain:** Node 20 + TypeScript, viem, pino
- **Network:** Mantle Sepolia (chain 5003) for dev, Mantle Mainnet (chain 5000) for production
- **Inference:** Allora Network on-chain feeds
- **Identity:** ERC-8004 reputation registry

## Local setup

Prerequisites: Node 20+, [Foundry](https://book.getfoundry.sh/getting-started/installation), git.

```bash
git clone https://github.com/antikythera-labs/mapa.git
cd mapa
cp .env.example .env  # fill values

# Contracts
cd contracts
forge install
forge build
forge test

# Frontend
cd ../frontend
npm install
npm run dev   # http://localhost:3000

# Off-chain scripts
cd ../scripts
npm install
npm run smoke-test
```

## Deployed addresses

> Will be filled in as deployment lands. Track progress in the [project board](https://github.com/antikythera-labs/mapa/projects).

| Contract | Mantle Sepolia | Mantle Mainnet |
|---|---|---|
| `ArenaRegistry`  | _pending_ | _pending_ |
| `BetMarket`      | _pending_ | _pending_ |
| `OddsOracle`     | _pending_ | _pending_ |

## Roadmap

- **Phase A** — core contracts on Sepolia (ArenaRegistry, BetMarket, OddsOracle) ← _in progress_
- **Phase B** — off-chain oracle pipeline + RealClaw indexer
- **Phase C** — frontend with leaderboard + bet form
- **Phase D** — design system, hi-fi prototype, polish (parallel)
- **Phase E** — Mantle Mainnet deploy + verification
- **Phase F** — public launch + DoraHacks submission

Detailed plan and status lives in `.business/plans/` (private to the team).

## Disclaimer

MAPA is a skill-based prediction market on verifiable on-chain agent performance. It is **not gambling**, but please do not use it from jurisdictions where prediction markets are restricted. UK/US users will see a geo-disclaimer on the live frontend.

This is hackathon-stage software. Contracts will be self-audited and Slither-scanned but not externally audited before mainnet deploy. Use only test funds.

## Team

**Antikythera Labs** — solo builder + Claude Code (Opus 4.7) as primary developer. The product is named after the [Antikythera mechanism](https://en.wikipedia.org/wiki/Antikythera_mechanism) — an ancient Greek analog computer, considered the world's first mechanical "agent."

## License

MIT — see [LICENSE](LICENSE).

## Links

- Hackathon: [Mantle Turing Test 2026 on DoraHacks](https://dorahacks.io/hackathon/mantle-turing-test)
- Mantle network: [mantle.xyz](https://www.mantle.xyz/)
- ERC-8004 EIP: [eips.ethereum.org/EIPS/eip-8004](https://eips.ethereum.org/EIPS/eip-8004)
- Allora Network: [allora.network](https://www.allora.network/)
