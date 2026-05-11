/**
 * MAPA Phase A2 — end-to-end smoke test on Mantle Sepolia.
 *
 * Flow:
 *   1. Derive 2 bettor EOAs (B, C) deterministically from AGENTS_SEED.
 *   2. Fund bettors: ~0.01 MNT for gas + 10/30 mock USDC for stakes.
 *   3. Approvals: deployer + B + C approve BetMarket for their stakes.
 *   4. createMatch(agentA=1, agentB=2, windowSec=60).
 *   5. placeBet × 3: deployer→A (20), B→A (10), C→B (30). Total pool 60 USDC.
 *   6. Wait until block.timestamp >= deadline (poll RPC, no fixed sleep).
 *   7. Oracle signs (chainId, betMarket, matchId, pnlA, pnlB) → resolveMatch.
 *   8. claimWinnings: deployer + B (winners on AgentA), expect specific payouts.
 *   9. Assert: 6 events emitted, payouts match formula within 1 wei, exit 0.
 *
 * Expected payouts (fee=2%):
 *   gross=60 USDC, fee=1.2 USDC, netPool=58.8 USDC, totalA=30 USDC
 *   deployer (staked 20 on A) → 20 * 58.8 / 30 = 39.200000 USDC
 *   bettorB  (staked 10 on A) → 10 * 58.8 / 30 = 19.600000 USDC
 *   bettorC  (staked 30 on B) → 0 (loser)
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  formatUnits,
  http,
  keccak256,
  parseAbi,
  parseEventLogs,
  type Address,
  type Hex,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createHash } from 'node:crypto';
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
// ABIs
// ──────────────────────────────────────────────────────────────
const usdcAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
  'function allowance(address,address) view returns (uint256)',
  'function approve(address,uint256) returns (bool)',
  'function mint(address,uint256)',
]);

const betMarketAbi = parseAbi([
  'function createMatch(uint256 agentA, uint256 agentB, uint256 windowSec) returns (uint256)',
  'function placeBet(uint256 matchId, uint8 choice, uint256 amount)',
  'function resolveMatch(uint256 matchId, int256 pnlA, int256 pnlB, bytes signature)',
  'function claimWinnings(uint256 matchId)',
  'function payoutOf(uint256 matchId, address bettor) view returns (uint256)',
  'function oracle() view returns (address)',
  'function FEE_BPS() view returns (uint256)',
  'event MatchCreated(uint256 indexed matchId, uint256 indexed agentA, uint256 indexed agentB, uint64 deadline)',
  'event BetPlaced(uint256 indexed matchId, address indexed bettor, uint8 choice, uint256 amount)',
  'event MatchResolved(uint256 indexed matchId, uint8 winner, int256 pnlA, int256 pnlB)',
  'event WinningsClaimed(uint256 indexed matchId, address indexed bettor, uint256 amount)',
]);

// ──────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────
function req(n: string): string {
  const v = process.env[n];
  if (!v || v.trim() === '') throw new Error(`Missing env var: ${n}`);
  return v.trim();
}

function reqPk(n: string): Hex {
  const raw = req(n);
  const pk = (raw.startsWith('0x') ? raw : `0x${raw}`).toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(pk)) throw new Error(`${n}: not a 32-byte hex private key`);
  return pk as Hex;
}

function deriveBettorKey(seed: string, label: string): Hex {
  const buf = createHash('sha256').update(`${seed}|MAPA-BETTOR|${label}`).digest();
  return `0x${buf.toString('hex')}` as Hex;
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// 6-decimal USDC literals
const USDC = (n: number) => BigInt(Math.round(n * 1e6));

// Match enum mirrors
const Choice = { None: 0, AgentA: 1, AgentB: 2 } as const;
const Winner = { None: 0, AgentA: 1, AgentB: 2, Tie: 3 } as const;

// ──────────────────────────────────────────────────────────────
async function main() {
  const t0 = Date.now();
  const rpc = req('MANTLE_SEPOLIA_RPC_URL');
  const deployerPk = reqPk('DEPLOYER_PRIVATE_KEY');
  const oraclePk = reqPk('ORACLE_PRIVATE_KEY');
  const seed = req('AGENTS_SEED');

  const usdcAddr = req('USDC_ADDRESS_SEPOLIA') as Address;
  const betMarketAddr = req('NEXT_PUBLIC_BET_MARKET_ADDRESS') as Address;

  const deployer = privateKeyToAccount(deployerPk);
  const oracle = privateKeyToAccount(oraclePk);
  const bettorB = privateKeyToAccount(deriveBettorKey(seed, 'B'));
  const bettorC = privateKeyToAccount(deriveBettorKey(seed, 'C'));

  const transport = http(rpc);
  const pub = createPublicClient({ chain: mantleSepolia, transport });
  const wDeployer = createWalletClient({ chain: mantleSepolia, transport, account: deployer });
  const wB = createWalletClient({ chain: mantleSepolia, transport, account: bettorB });
  const wC = createWalletClient({ chain: mantleSepolia, transport, account: bettorC });
  const wOracle = createWalletClient({ chain: mantleSepolia, transport, account: oracle });

  console.log('━━━ MAPA smoke-test ━━━');
  console.log('Deployer:', deployer.address);
  console.log('Oracle:  ', oracle.address);
  console.log('BettorB: ', bettorB.address);
  console.log('BettorC: ', bettorC.address);

  // ── Oracle wiring check ────────────────────────────────────
  const onchainOracle = (await pub.readContract({
    address: betMarketAddr, abi: betMarketAbi, functionName: 'oracle',
  })) as Address;
  if (onchainOracle.toLowerCase() !== oracle.address.toLowerCase()) {
    throw new Error(`BetMarket.oracle mismatch: on-chain=${onchainOracle}, env=${oracle.address}`);
  }

  // ── Phase 1: fund bettors with MNT (sequential — same sender) ──
  // Need ≥ ~0.015 MNT to cover approve + placeBet + claim at ~50 gwei.
  // Top up to 0.03 MNT for buffer.
  const minGas = 25_000_000_000_000_000n; // 0.025 MNT
  const topUpTarget = 30_000_000_000_000_000n; // 0.030 MNT
  for (const [label, bettor] of [['B', bettorB], ['C', bettorC]] as const) {
    const bal = await pub.getBalance({ address: bettor.address });
    if (bal < minGas) {
      const send = topUpTarget - bal;
      console.log(`Funding bettor${label} with ${(Number(send) / 1e18).toFixed(4)} MNT ...`);
      const hash = await wDeployer.sendTransaction({ to: bettor.address, value: send });
      await pub.waitForTransactionReceipt({ hash });
    }
  }

  // ── Phase 2: mint surplus USDC + max-approve (parallel across senders) ──
  // Mint 1000 USDC to each + approve maxuint256 → idempotent over many runs.
  // This is testnet smoke-only behaviour; production never max-approves mock USDC.
  const SURPLUS = USDC(1000);
  const MAX_UINT256 = (1n << 256n) - 1n;
  const SAFE_ALLOWANCE_FLOOR = USDC(100); // re-approve only if dropped below this

  type SenderJob = readonly [
    label: string,
    w: typeof wDeployer,
    addr: Address,
    minBal: bigint,
    minAllow: bigint,
  ];
  const senderJobs: readonly SenderJob[] = [
    ['deployer', wDeployer, deployer.address, USDC(20), SAFE_ALLOWANCE_FLOOR] as const,
    ['bettorB',  wB,        bettorB.address,  USDC(10), SAFE_ALLOWANCE_FLOOR] as const,
    ['bettorC',  wC,        bettorC.address,  USDC(30), SAFE_ALLOWANCE_FLOOR] as const,
  ];

  await Promise.all(senderJobs.map(async ([label, w, addr, minBal, minAllow]) => {
    const [bal, allow] = await Promise.all([
      pub.readContract({ address: usdcAddr, abi: usdcAbi, functionName: 'balanceOf', args: [addr] }) as Promise<bigint>,
      pub.readContract({ address: usdcAddr, abi: usdcAbi, functionName: 'allowance', args: [addr, betMarketAddr] }) as Promise<bigint>,
    ]);
    if (bal < minBal) {
      const mintAmt = SURPLUS;
      console.log(`Minting ${formatUnits(mintAmt, 6)} USDC → ${label} ...`);
      const hash = await w.writeContract({
        address: usdcAddr, abi: usdcAbi, functionName: 'mint',
        args: [addr, mintAmt],
      });
      await pub.waitForTransactionReceipt({ hash });
    }
    if (allow < minAllow) {
      console.log(`Approving BetMarket from ${label} (max) ...`);
      const hash = await w.writeContract({
        address: usdcAddr, abi: usdcAbi, functionName: 'approve',
        args: [betMarketAddr, MAX_UINT256],
      });
      await pub.waitForTransactionReceipt({ hash });
    }
  }));

  // ── Create match (agent1 vs agent2, 60s window) ────────────
  console.log('createMatch(agentA=1, agentB=2, window=60s) ...');
  let matchId = 0n;
  let deadline = 0n;
  {
    const hash = await wDeployer.writeContract({
      address: betMarketAddr, abi: betMarketAbi, functionName: 'createMatch',
      args: [1n, 2n, 60n],
    });
    const r = await pub.waitForTransactionReceipt({ hash });
    const evts = parseEventLogs({ abi: betMarketAbi, logs: r.logs, eventName: 'MatchCreated' });
    if (evts.length === 0) throw new Error('MatchCreated event not emitted');
    matchId = evts[0].args.matchId;
    deadline = BigInt(evts[0].args.deadline);
    console.log(`    matchId=${matchId} deadline=${deadline} tx=${hash}`);
  }

  // ── 3 bets (parallel — different senders, independent nonces) ──
  const bets = [
    ['deployer', wDeployer, Choice.AgentA, USDC(20)] as const,
    ['bettorB',  wB,        Choice.AgentA, USDC(10)] as const,
    ['bettorC',  wC,        Choice.AgentB, USDC(30)] as const,
  ];
  const betResults = await Promise.all(bets.map(async ([label, w, choice, amount]) => {
    const hash = await w.writeContract({
      address: betMarketAddr, abi: betMarketAbi, functionName: 'placeBet',
      args: [matchId, choice, amount],
    });
    const r = await pub.waitForTransactionReceipt({ hash });
    const evts = parseEventLogs({ abi: betMarketAbi, logs: r.logs, eventName: 'BetPlaced' });
    if (evts.length !== 1) throw new Error(`BetPlaced expected 1, got ${evts.length} for ${label}`);
    return { label, choice, amount, hash };
  }));
  const betEventCount = betResults.length;
  for (const b of betResults) {
    console.log(`    bet[${b.label}] choice=${b.choice} amount=${formatUnits(b.amount, 6)} tx=${b.hash}`);
  }

  // ── Wait for deadline (poll latest block timestamp) ────────
  console.log(`Waiting for deadline (${deadline}) ...`);
  for (;;) {
    const block = await pub.getBlock({ blockTag: 'latest' });
    if (block.timestamp >= deadline) {
      console.log(`    block.timestamp=${block.timestamp} ≥ ${deadline}`);
      break;
    }
    const remaining = Number(deadline - block.timestamp);
    process.stdout.write(`    ${remaining}s remaining ...\r`);
    await sleep(3000);
  }

  // ── Build PnL signature ────────────────────────────────────
  // BetMarket digest: keccak256(abi.encode(block.chainid, address(this), matchId, pnlA, pnlB))
  // ECDSA.recover with toEthSignedMessageHash — so we sign EIP-191 raw digest.
  const pnlA = 100n;
  const pnlB = -50n;
  const digest = keccak256(
    encodeAbiParameters(
      [
        { type: 'uint256' }, { type: 'address' }, { type: 'uint256' },
        { type: 'int256' }, { type: 'int256' },
      ],
      [5003n, betMarketAddr, matchId, pnlA, pnlB],
    ),
  );
  const signature = await wOracle.signMessage({ message: { raw: digest } });

  console.log('resolveMatch ...');
  let resolveEventOk = false;
  {
    const hash = await wDeployer.writeContract({
      address: betMarketAddr, abi: betMarketAbi, functionName: 'resolveMatch',
      args: [matchId, pnlA, pnlB, signature],
    });
    const r = await pub.waitForTransactionReceipt({ hash });
    const evts = parseEventLogs({ abi: betMarketAbi, logs: r.logs, eventName: 'MatchResolved' });
    if (evts.length !== 1) throw new Error('MatchResolved not emitted');
    if (evts[0].args.winner !== Winner.AgentA) {
      throw new Error(`Winner expected AgentA(1), got ${evts[0].args.winner}`);
    }
    resolveEventOk = true;
    console.log(`    resolved winner=AgentA tx=${hash}`);
  }

  // ── Expected payouts (from contract formula, exact bigint math) ──
  // gross=60, fee=2%=1.2 → netPool=58.8, totalA=30
  // deployer (sA=20): 20 * 58_800_000 / 30 = 39_200_000
  // bettorB  (sA=10): 10 * 58_800_000 / 30 = 19_600_000
  const gross = USDC(60);
  const fee = (gross * 200n) / 10_000n;
  const netPool = gross - fee;
  const totalA = USDC(30);
  const expDeployer = (USDC(20) * netPool) / totalA;
  const expBettorB = (USDC(10) * netPool) / totalA;
  console.log(`Expected: deployer=${formatUnits(expDeployer, 6)} bettorB=${formatUnits(expBettorB, 6)} USDC`);

  // payoutOf preview
  const previewD = (await pub.readContract({
    address: betMarketAddr, abi: betMarketAbi, functionName: 'payoutOf',
    args: [matchId, deployer.address],
  })) as bigint;
  const previewB = (await pub.readContract({
    address: betMarketAddr, abi: betMarketAbi, functionName: 'payoutOf',
    args: [matchId, bettorB.address],
  })) as bigint;
  if (previewD !== expDeployer) throw new Error(`payoutOf(deployer) preview mismatch: ${previewD} vs ${expDeployer}`);
  if (previewB !== expBettorB)  throw new Error(`payoutOf(bettorB) preview mismatch: ${previewB} vs ${expBettorB}`);
  console.log('    payoutOf preview matches expected');

  // ── Claim (parallel — different senders) ───────────────────
  const claims = [
    ['deployer', wDeployer, expDeployer] as const,
    ['bettorB',  wB,        expBettorB ] as const,
  ];
  const claimResults = await Promise.all(claims.map(async ([label, w, expected]) => {
    const balBefore = (await pub.readContract({
      address: usdcAddr, abi: usdcAbi, functionName: 'balanceOf', args: [w.account.address],
    })) as bigint;
    const hash = await w.writeContract({
      address: betMarketAddr, abi: betMarketAbi, functionName: 'claimWinnings',
      args: [matchId],
    });
    const r = await pub.waitForTransactionReceipt({ hash });
    const evts = parseEventLogs({ abi: betMarketAbi, logs: r.logs, eventName: 'WinningsClaimed' });
    if (evts.length !== 1) throw new Error(`WinningsClaimed missing for ${label}`);
    const claimed = evts[0].args.amount;
    if (claimed !== expected) throw new Error(`${label} claim ${claimed} ≠ expected ${expected}`);
    const balAfter = (await pub.readContract({
      address: usdcAddr, abi: usdcAbi, functionName: 'balanceOf', args: [w.account.address],
    })) as bigint;
    const delta = balAfter - balBefore;
    if (delta !== expected) throw new Error(`${label} USDC delta ${delta} ≠ expected ${expected}`);
    return { label, claimed, hash };
  }));
  const claimEventCount = claimResults.length;
  let claimSum = 0n;
  for (const c of claimResults) {
    claimSum += c.claimed;
    console.log(`    claim[${c.label}] amount=${formatUnits(c.claimed, 6)} USDC tx=${c.hash}`);
  }

  // ── Payout invariant: sum of payouts ≈ netPool (within 1 wei) ──
  const diff = claimSum > netPool ? claimSum - netPool : netPool - claimSum;
  if (diff > 1n) {
    throw new Error(`Payout sum ${claimSum} differs from netPool ${netPool} by ${diff} wei (>1)`);
  }

  // ── Event tally ────────────────────────────────────────────
  const eventsTotal = 1 + betEventCount + (resolveEventOk ? 1 : 0) + claimEventCount;
  console.log('━━━ smoke-test PASS ━━━');
  console.log(`Events: MatchCreated=1 BetPlaced=${betEventCount} MatchResolved=${resolveEventOk ? 1 : 0} WinningsClaimed=${claimEventCount} (total ${eventsTotal})`);
  console.log(`Payout sum ${formatUnits(claimSum, 6)} vs netPool ${formatUnits(netPool, 6)} (Δ ${diff} wei)`);
  console.log(`Wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

main().catch((e) => {
  console.error('━━━ smoke-test FAIL ━━━');
  console.error(e);
  process.exit(1);
});
