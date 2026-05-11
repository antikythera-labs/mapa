/**
 * MAPA Phase A2 — seed 10 operated agents on Mantle Sepolia.
 *
 * Flow:
 *   1. Derive 10 deterministic agent EOAs from AGENTS_SEED (sha256(seed|MAPA|slug)).
 *   2. Ensure deployer holds enough mock USDC (mint if short) + approves registry.
 *   3. ArenaRegistry.registerAgent for each (skips if agentIdOf[addr] != 0).
 *   4. MockReputation.setEloBatch with 1500..1900 spread.
 *   5. ERC8004ReputationAdapter.mirrorElo from JUDGE EOA for each agent (bonus path).
 *   6. Verify on-chain Elo, write manifest to scripts/data/agents.json.
 *
 * Idempotent: rerunning skips already-registered agents. Mirror runs every time
 * (cheap, and re-emitting FeedbackGiven on ERC-8004 is harmless).
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  formatEther,
  formatUnits,
  http,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');
dotenvConfig({ path: resolve(REPO_ROOT, '.env.local') });

// ──────────────────────────────────────────────────────────────
// Chain config (Mantle Sepolia)
// ──────────────────────────────────────────────────────────────
const mantleSepolia = defineChain({
  id: 5003,
  name: 'Mantle Sepolia Testnet',
  nativeCurrency: { decimals: 18, name: 'Mantle', symbol: 'MNT' },
  rpcUrls: { default: { http: ['https://rpc.sepolia.mantle.xyz'] } },
  blockExplorers: {
    default: { name: 'Mantlescan', url: 'https://sepolia.mantlescan.xyz' },
  },
});

// ──────────────────────────────────────────────────────────────
// Persona table — 10 operated paper-trading agents
// (slugs map to LLM personas the orchestrator will run in Phase B)
// ──────────────────────────────────────────────────────────────
type Tier = 'free' | 'paid';
interface AgentSpec {
  slug: string;
  model: string;
  tier: Tier;
  initialElo: number;
  persona: string;
}

const AGENTS: AgentSpec[] = [
  { slug: 'claude-sonnet-strategist', model: 'claude-sonnet-4-6',  tier: 'paid', initialElo: 1900, persona: 'long-horizon strategist with low-frequency conviction trades' },
  { slug: 'gpt54mini-arb',            model: 'gpt-5.4-mini',        tier: 'paid', initialElo: 1850, persona: 'cross-venue arbitrage hunter, latency-sensitive' },
  { slug: 'claude-haiku-quant',       model: 'claude-haiku-4-5',    tier: 'paid', initialElo: 1800, persona: 'fast quantitative reflexes, high tick churn' },
  { slug: 'gemini-pro-macro',         model: 'gemini-2.5-pro',      tier: 'paid', initialElo: 1750, persona: 'macro thesis trader, prefers trend continuation' },
  { slug: 'mistral-small-swing',      model: 'mistral-small-3.1',   tier: 'paid', initialElo: 1700, persona: 'swing trader, 4-8h holding windows' },
  { slug: 'deepseek-momentum',        model: 'deepseek-v3.2',       tier: 'free', initialElo: 1650, persona: 'momentum follower, scales into breakouts' },
  { slug: 'llama4-scout-trend',       model: 'llama-4-scout',       tier: 'free', initialElo: 1600, persona: 'trend rider with tight stops' },
  { slug: 'qwen36-meanrev',           model: 'qwen-3.6-27b',        tier: 'free', initialElo: 1550, persona: 'mean-reversion specialist, fades extremes' },
  { slug: 'phi4-contrarian',          model: 'phi-4',               tier: 'free', initialElo: 1525, persona: 'contrarian, takes other side of crowd' },
  { slug: 'gemini-flash-trend',       model: 'gemini-2.5-flash',    tier: 'free', initialElo: 1500, persona: 'baseline 50/50 prior, naive trend follower' },
];

// ──────────────────────────────────────────────────────────────
// ABIs (parseAbi → typed)
// ──────────────────────────────────────────────────────────────
const mockUsdcAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function mint(address,uint256)',
]);

const registryAbi = parseAbi([
  'function registerAgent(address agent, string name, address owner_) returns (uint256)',
  'function agentIdOf(address) view returns (uint256)',
  'function nextAgentId() view returns (uint256)',
  'function stakeAmount() view returns (uint256)',
  'event AgentRegistered(uint256 indexed agentId, address indexed agent, address indexed owner, string name, uint256 stake)',
]);

const reputationAbi = parseAbi([
  'function setEloBatch(uint256[] agentIds, uint256[] elos)',
  'function getElo(uint256) view returns (uint256)',
]);

const adapterAbi = parseAbi([
  'function mirrorElo(uint256 agentId, int128 elo)',
  'function judge() view returns (address)',
]);

// ──────────────────────────────────────────────────────────────
// Env / key helpers
// ──────────────────────────────────────────────────────────────
function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === '') throw new Error(`Missing env var: ${name}`);
  return v.trim();
}

function reqPk(name: string): Hex {
  const raw = reqEnv(name);
  const pk = (raw.startsWith('0x') ? raw : `0x${raw}`).toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(pk)) {
    throw new Error(`${name}: expected 32-byte hex private key`);
  }
  return pk as Hex;
}

function deriveAgentKey(seed: string, slug: string): Hex {
  const buf = createHash('sha256').update(`${seed}|MAPA|${slug}`).digest();
  return `0x${buf.toString('hex')}` as Hex;
}

// ──────────────────────────────────────────────────────────────
// Manifest
// ──────────────────────────────────────────────────────────────
interface AgentRecord {
  agentId: number;
  slug: string;
  model: string;
  tier: Tier;
  initialElo: number;
  agentAddress: Address;
  ownerAddress: Address;
}

const DATA_DIR = resolve(__dirname, '../data');
const MANIFEST = resolve(DATA_DIR, 'agents.json');

// ──────────────────────────────────────────────────────────────
async function main() {
  const rpcUrl = reqEnv('MANTLE_SEPOLIA_RPC_URL');
  const deployerPk = reqPk('DEPLOYER_PRIVATE_KEY');
  const judgePk = reqPk('JUDGE_PRIVATE_KEY');
  const seed = reqEnv('AGENTS_SEED');
  if (!/^[0-9a-fA-F]{32,}$/.test(seed)) {
    throw new Error('AGENTS_SEED must be ≥16 bytes of hex (generate via `openssl rand -hex 32`).');
  }

  const usdcAddr = reqEnv('USDC_ADDRESS_SEPOLIA') as Address;
  const registryAddr = reqEnv('NEXT_PUBLIC_ARENA_REGISTRY_ADDRESS') as Address;
  const reputationAddr = reqEnv('NEXT_PUBLIC_MOCK_REPUTATION_ADDRESS') as Address;
  const adapterAddr = reqEnv('NEXT_PUBLIC_ERC8004_ADAPTER_ADDRESS') as Address;

  const deployer = privateKeyToAccount(deployerPk);
  const judge = privateKeyToAccount(judgePk);

  const transport = http(rpcUrl);
  const publicClient = createPublicClient({ chain: mantleSepolia, transport });
  const deployerClient = createWalletClient({ chain: mantleSepolia, transport, account: deployer });
  const judgeClient = createWalletClient({ chain: mantleSepolia, transport, account: judge });

  console.log('━━━ MAPA seed-agents (Phase A2) ━━━');
  console.log('Chain:    Mantle Sepolia (5003)');
  console.log('Deployer:', deployer.address);
  console.log('Judge:   ', judge.address);
  console.log('Registry:', registryAddr);
  console.log('USDC:    ', usdcAddr);

  // ── Pre-flight: balances + adapter wiring ──────────────────
  const [deployerMnt, judgeMnt] = await Promise.all([
    publicClient.getBalance({ address: deployer.address }),
    publicClient.getBalance({ address: judge.address }),
  ]);
  console.log(`Deployer MNT balance: ${formatEther(deployerMnt)}`);
  console.log(`Judge MNT balance:    ${formatEther(judgeMnt)}`);
  if (deployerMnt < 100_000_000_000_000_000n) {
    throw new Error('Deployer has <0.1 MNT — fund the EOA before running.');
  }
  if (judgeMnt < 50_000_000_000_000_000n) {
    throw new Error('Judge has <0.05 MNT — fund the EOA before running (10 mirror txs).');
  }

  const adapterJudge = (await publicClient.readContract({
    address: adapterAddr, abi: adapterAbi, functionName: 'judge',
  })) as Address;
  if (adapterJudge.toLowerCase() !== judge.address.toLowerCase()) {
    throw new Error(
      `Adapter.judge mismatch: on-chain=${adapterJudge}, env JUDGE=${judge.address}`,
    );
  }

  // ── USDC funding + approval ────────────────────────────────
  const stakeAmount = (await publicClient.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'stakeAmount',
  })) as bigint;
  const totalStake = stakeAmount * BigInt(AGENTS.length);
  console.log(`Stake: ${formatUnits(stakeAmount, 6)} USDC × ${AGENTS.length} = ${formatUnits(totalStake, 6)} USDC`);

  const usdcBalance = (await publicClient.readContract({
    address: usdcAddr, abi: mockUsdcAbi, functionName: 'balanceOf', args: [deployer.address],
  })) as bigint;
  if (usdcBalance < totalStake) {
    const need = totalStake - usdcBalance;
    console.log(`Minting ${formatUnits(need, 6)} mock USDC to deployer ...`);
    const hash = await deployerClient.writeContract({
      address: usdcAddr, abi: mockUsdcAbi, functionName: 'mint',
      args: [deployer.address, need],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`    mint tx: ${hash}`);
  }

  const allowance = (await publicClient.readContract({
    address: usdcAddr, abi: mockUsdcAbi, functionName: 'allowance',
    args: [deployer.address, registryAddr],
  })) as bigint;
  if (allowance < totalStake) {
    console.log(`Approving registry for ${formatUnits(totalStake, 6)} USDC ...`);
    const hash = await deployerClient.writeContract({
      address: usdcAddr, abi: mockUsdcAbi, functionName: 'approve',
      args: [registryAddr, totalStake],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`    approve tx: ${hash}`);
  }

  // ── Register agents ────────────────────────────────────────
  const records: AgentRecord[] = [];
  for (const spec of AGENTS) {
    const key = deriveAgentKey(seed, spec.slug);
    const agentAddress = privateKeyToAccount(key).address;
    const owner = deployer.address;

    const existing = (await publicClient.readContract({
      address: registryAddr, abi: registryAbi, functionName: 'agentIdOf',
      args: [agentAddress],
    })) as bigint;

    let agentId: number;
    if (existing > 0n) {
      agentId = Number(existing);
      console.log(`[skip ] ${spec.slug.padEnd(28)} agentId=${agentId} (already registered)`);
    } else {
      const hash = await deployerClient.writeContract({
        address: registryAddr, abi: registryAbi, functionName: 'registerAgent',
        args: [agentAddress, spec.slug, owner],
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      const evts = parseEventLogs({
        abi: registryAbi, logs: receipt.logs, eventName: 'AgentRegistered',
      });
      if (evts.length === 0) throw new Error(`No AgentRegistered event for ${spec.slug}`);
      agentId = Number(evts[0].args.agentId);
      console.log(`[reg  ] ${spec.slug.padEnd(28)} agentId=${agentId} tx=${hash}`);
    }

    records.push({
      agentId,
      slug: spec.slug,
      model: spec.model,
      tier: spec.tier,
      initialElo: spec.initialElo,
      agentAddress,
      ownerAddress: owner,
    });
  }

  // ── Set initial Elo (batch) ────────────────────────────────
  console.log('Setting initial Elo (batch) ...');
  {
    const ids = records.map((r) => BigInt(r.agentId));
    const elos = records.map((r) => BigInt(r.initialElo));
    const hash = await deployerClient.writeContract({
      address: reputationAddr, abi: reputationAbi, functionName: 'setEloBatch',
      args: [ids, elos],
    });
    await publicClient.waitForTransactionReceipt({ hash });
    console.log(`    setEloBatch tx: ${hash}`);
  }

  // ── Verify Elo readback ────────────────────────────────────
  for (const r of records) {
    const elo = (await publicClient.readContract({
      address: reputationAddr, abi: reputationAbi, functionName: 'getElo',
      args: [BigInt(r.agentId)],
    })) as bigint;
    if (Number(elo) !== r.initialElo) {
      throw new Error(`Elo mismatch for ${r.slug}: got ${elo}, expected ${r.initialElo}`);
    }
  }
  console.log(`    verified getElo for ${records.length} agents`);

  // ── Mirror to ERC-8004 (judge EOA, bonus path) ─────────────
  console.log('Mirroring Elo to ERC-8004 via adapter (judge) ...');
  for (const r of records) {
    try {
      const hash = await judgeClient.writeContract({
        address: adapterAddr, abi: adapterAbi, functionName: 'mirrorElo',
        args: [BigInt(r.agentId), BigInt(r.initialElo)],
      });
      await publicClient.waitForTransactionReceipt({ hash });
      console.log(`    [${String(r.agentId).padStart(2)}] ${r.slug.padEnd(28)} mirror tx=${hash}`);
    } catch (e) {
      const msg = (e as { shortMessage?: string; message: string }).shortMessage
        ?? (e as Error).message;
      console.warn(`    [${r.agentId}] ${r.slug} mirror FAILED (non-critical): ${msg}`);
    }
  }

  // ── Write manifest ─────────────────────────────────────────
  if (!existsSync(DATA_DIR)) mkdirSync(DATA_DIR, { recursive: true });
  const manifest = {
    chainId: 5003,
    seededAt: new Date().toISOString(),
    contracts: {
      arenaRegistry: registryAddr,
      mockReputation: reputationAddr,
      erc8004Adapter: adapterAddr,
      mockUsdc: usdcAddr,
    },
    judge: judge.address,
    deployer: deployer.address,
    agents: records,
  };
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2));
  console.log(`Manifest: ${MANIFEST}`);
  console.log('━━━ done ━━━');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
