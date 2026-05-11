/**
 * MAPA Phase B — LLM Orchestrator MVP (single-cycle, stub LLM).
 *
 * For each of the 10 operated agents, decide a trade action
 *   (hold | long | short) + sizeBp (0..10000) based on persona
 *   and current BTC/USD market context, then emit on-chain via
 *   BetMarket.recordDecision(agentId, action, sizeBp) — onlyOracle.
 *
 * This is a STUB pipeline:
 *   - LLM responses are deterministic persona-rules, not actual LLM calls.
 *     Real LLM integration requires LLM_PROVIDER + API keys in .env.local.
 *   - Market context comes from CoinGecko free API. Real Allora BTC/USD
 *     topic-1 integration is Phase B2.
 *
 * Output:
 *   - 10 AgentDecision events on Mantle Sepolia
 *   - scripts/data/decisions-{ISO}.json snapshot for replay/audit
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  http,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
dotenvConfig({ path: resolve(REPO_ROOT, '.env.local') });

const mantleSepolia = defineChain({
  id: 5003,
  name: 'Mantle Sepolia Testnet',
  nativeCurrency: { decimals: 18, name: 'Mantle', symbol: 'MNT' },
  rpcUrls: { default: { http: ['https://rpc.sepolia.mantle.xyz'] } },
});

// ──────────────────────────────────────────────────────────────
// Types
// ──────────────────────────────────────────────────────────────
type Tier = 'free' | 'paid';
type Action = 0 | 1 | 2; // 0=hold, 1=long, 2=short

interface AgentRecord {
  agentId: number;
  slug: string;
  model: string;
  tier: Tier;
  initialElo: number;
  agentAddress: Address;
  ownerAddress: Address;
}

interface Manifest {
  chainId: number;
  agents: AgentRecord[];
}

interface MarketContext {
  source: string;
  spotUsd: number;
  pct24h: number;
  fetchedAt: string;
}

interface Decision {
  agentId: number;
  slug: string;
  action: Action;
  actionLabel: 'hold' | 'long' | 'short';
  sizeBp: number;
  rationale: string;
}

const ACTION_LABELS = { 0: 'hold', 1: 'long', 2: 'short' } as const;

// ──────────────────────────────────────────────────────────────
// Market context (CoinGecko free tier)
// ──────────────────────────────────────────────────────────────
async function fetchMarketContext(): Promise<MarketContext> {
  const url = 'https://api.coingecko.com/api/v3/simple/price'
    + '?ids=bitcoin&vs_currencies=usd&include_24hr_change=true';
  const res = await fetch(url);
  if (!res.ok) throw new Error(`CoinGecko ${res.status}: ${await res.text()}`);
  const json = await res.json() as { bitcoin: { usd: number; usd_24h_change: number } };
  return {
    source: 'coingecko.simple/bitcoin',
    spotUsd: json.bitcoin.usd,
    pct24h: json.bitcoin.usd_24h_change,
    fetchedAt: new Date().toISOString(),
  };
}

// ──────────────────────────────────────────────────────────────
// Persona-driven stub decision policy.
// To replace with a real LLM call: swap this for an async function that
// posts (slug, persona, market_context) to the model API and parses JSON.
// ──────────────────────────────────────────────────────────────
function decideStub(slug: string, mkt: MarketContext): { action: Action; sizeBp: number; rationale: string } {
  const t = mkt.pct24h; // %
  const up = t > 0;
  const strongUp = t > 0.5;
  const strongDown = t < -0.5;
  const veryStrongUp = t > 1.0;
  const veryStrongDown = t < -1.0;

  switch (slug) {
    case 'claude-sonnet-strategist':
      if (veryStrongUp) return { action: 1, sizeBp: 6000, rationale: 'long-horizon conviction on strong uptrend (>1%/24h)' };
      if (veryStrongDown) return { action: 2, sizeBp: 6000, rationale: 'long-horizon short on strong downtrend (<-1%/24h)' };
      return { action: 0, sizeBp: 0, rationale: 'insufficient conviction, holding' };
    case 'gpt54mini-arb':
      return { action: 0, sizeBp: 0, rationale: 'no arbitrage opportunity in single-feed context' };
    case 'claude-haiku-quant':
      return { action: up ? 1 : 2, sizeBp: 4000, rationale: `fast reflex, follow ${up ? 'up' : 'down'} momentum` };
    case 'gemini-pro-macro':
      if (strongUp) return { action: 1, sizeBp: 7000, rationale: 'macro continuation, large long' };
      if (strongDown) return { action: 2, sizeBp: 7000, rationale: 'macro continuation, large short' };
      return { action: 0, sizeBp: 0, rationale: 'macro signal too weak' };
    case 'mistral-small-swing':
      return { action: up ? 1 : 2, sizeBp: 3000, rationale: 'swing trade with 24h trend' };
    case 'deepseek-momentum':
      return { action: up ? 1 : 2, sizeBp: 5000, rationale: 'momentum follower' };
    case 'llama4-scout-trend':
      return { action: up ? 1 : 2, sizeBp: 4500, rationale: 'trend rider with tight stops' };
    case 'qwen36-meanrev':
      // mean reversion: bet AGAINST the current 24h move
      return { action: up ? 2 : 1, sizeBp: 3500, rationale: `fade the ${up ? 'uptrend' : 'downtrend'} (mean reversion)` };
    case 'phi4-contrarian':
      return { action: up ? 2 : 1, sizeBp: 4000, rationale: `contrarian: take other side of ${up ? 'longs' : 'shorts'}` };
    case 'gemini-flash-trend':
      return { action: up ? 1 : 2, sizeBp: 2500, rationale: 'naive trend follower (baseline)' };
    default:
      return { action: 0, sizeBp: 0, rationale: 'unknown persona, hold' };
  }
}

// ──────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────
function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === '') throw new Error(`Missing env var: ${name}`);
  return v.trim();
}
function reqPk(name: string): Hex {
  const raw = reqEnv(name);
  const pk = (raw.startsWith('0x') ? raw : `0x${raw}`).toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(pk)) throw new Error(`${name}: not 32-byte hex`);
  return pk as Hex;
}

const betMarketAbi = parseAbi([
  'function recordDecision(uint256 agentId, uint8 action, uint16 sizeBp)',
  'function oracle() view returns (address)',
  'function paused() view returns (bool)',
  'event AgentDecision(uint256 indexed agentId, uint8 action, uint16 sizeBp, uint64 timestamp)',
]);

// ──────────────────────────────────────────────────────────────
async function main() {
  const t0 = Date.now();
  const rpc = reqEnv('MANTLE_SEPOLIA_RPC_URL');
  const oraclePk = reqPk('ORACLE_PRIVATE_KEY');
  const betMarketAddr = reqEnv('NEXT_PUBLIC_BET_MARKET_ADDRESS') as Address;

  const oracle = privateKeyToAccount(oraclePk);
  const transport = http(rpc);
  const pub = createPublicClient({ chain: mantleSepolia, transport });
  const wOracle = createWalletClient({ chain: mantleSepolia, transport, account: oracle });

  // ── Load manifest ──────────────────────────────────────────
  const manifestPath = resolve(__dirname, '../data/agents.json');
  if (!existsSync(manifestPath)) {
    throw new Error(`Manifest not found: ${manifestPath}. Run seed-agents first.`);
  }
  const manifest: Manifest = JSON.parse(readFileSync(manifestPath, 'utf-8'));

  console.log('━━━ MAPA llm-orchestrator (Phase B MVP) ━━━');
  console.log('Oracle:    ', oracle.address);
  console.log('BetMarket: ', betMarketAddr);
  console.log('Agents:    ', manifest.agents.length);

  // ── Pre-flight checks ──────────────────────────────────────
  const [onchainOracle, paused, oracleMnt] = await Promise.all([
    pub.readContract({ address: betMarketAddr, abi: betMarketAbi, functionName: 'oracle' }) as Promise<Address>,
    pub.readContract({ address: betMarketAddr, abi: betMarketAbi, functionName: 'paused' }) as Promise<boolean>,
    pub.getBalance({ address: oracle.address }),
  ]);
  if (onchainOracle.toLowerCase() !== oracle.address.toLowerCase()) {
    throw new Error(`BetMarket.oracle on-chain (${onchainOracle}) ≠ env ORACLE (${oracle.address})`);
  }
  if (paused) throw new Error('BetMarket is paused — recordDecision will revert with EnforcedPause');
  console.log(`Oracle MNT: ${formatEther(oracleMnt)}`);
  if (oracleMnt < 50_000_000_000_000_000n) {
    throw new Error('Oracle has <0.05 MNT — top up for 10 recordDecision tx');
  }

  // ── Market context ─────────────────────────────────────────
  console.log('Fetching BTC/USD market context (CoinGecko) ...');
  const mkt = await fetchMarketContext();
  console.log(`    BTC=${mkt.spotUsd} USD, 24h change=${mkt.pct24h.toFixed(2)}%`);

  // ── Decide per agent ───────────────────────────────────────
  const decisions: Decision[] = manifest.agents.map((a) => {
    const d = decideStub(a.slug, mkt);
    return {
      agentId: a.agentId,
      slug: a.slug,
      action: d.action,
      actionLabel: ACTION_LABELS[d.action],
      sizeBp: d.sizeBp,
      rationale: d.rationale,
    };
  });

  console.log('Decisions:');
  for (const d of decisions) {
    console.log(`  [${String(d.agentId).padStart(2)}] ${d.slug.padEnd(28)} → ${d.actionLabel.padEnd(5)} sizeBp=${String(d.sizeBp).padStart(5)}  (${d.rationale})`);
  }

  // ── Emit AgentDecision events (sequential — same oracle nonce stream) ──
  console.log('Emitting AgentDecision events ...');
  let emitted = 0;
  for (const d of decisions) {
    const hash = await wOracle.writeContract({
      address: betMarketAddr, abi: betMarketAbi, functionName: 'recordDecision',
      args: [BigInt(d.agentId), d.action, d.sizeBp],
    });
    const r = await pub.waitForTransactionReceipt({ hash });
    const evts = parseEventLogs({ abi: betMarketAbi, logs: r.logs, eventName: 'AgentDecision' });
    if (evts.length !== 1) throw new Error(`AgentDecision not emitted for agentId=${d.agentId}`);
    const ev = evts[0].args;
    if (Number(ev.agentId) !== d.agentId || ev.action !== d.action || ev.sizeBp !== d.sizeBp) {
      throw new Error(`Event arg mismatch for agentId=${d.agentId}: expected (${d.action},${d.sizeBp}), got (${ev.action},${ev.sizeBp})`);
    }
    emitted += 1;
    console.log(`    [${String(d.agentId).padStart(2)}] ${d.actionLabel} ${d.sizeBp}bp  tx=${hash}`);
  }

  // ── Write decision snapshot ────────────────────────────────
  const dataDir = resolve(__dirname, '../data');
  if (!existsSync(dataDir)) mkdirSync(dataDir, { recursive: true });
  const snapPath = resolve(dataDir, `decisions-${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  writeFileSync(snapPath, JSON.stringify({
    chainId: 5003,
    cycleAt: new Date().toISOString(),
    oracle: oracle.address,
    betMarket: betMarketAddr,
    market: mkt,
    decisions,
  }, null, 2));

  console.log('━━━ orchestrator cycle PASS ━━━');
  console.log(`Emitted ${emitted}/10 AgentDecision events.`);
  console.log(`Snapshot: ${snapPath}`);
  console.log(`Wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

main().catch((e) => {
  console.error('━━━ orchestrator FAIL ━━━');
  console.error(e);
  process.exit(1);
});
