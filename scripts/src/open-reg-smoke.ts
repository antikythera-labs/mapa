/**
 * MAPA Phase A2 — open-registration smoke on Mantle Sepolia.
 *
 * Goal: prove ArenaRegistry.registerAgent is callable by an arbitrary external
 * EOA (not the deployer / oracle / judge). Closes the "open registration smoke"
 * criterion in `.business/plans/2026-05-10-mapa-plan.md` Phase A2.
 *
 * Flow:
 *   1. Derive a stable "external user" EOA and a stable "external agent" EOA
 *      from AGENTS_SEED (labels EXTERNAL-USER / EXTERNAL-AGENT-1). Stable so
 *      the script is idempotent — funded balances are not orphaned on rerun.
 *   2. If externalAgent is already registered, verify state and exit 0.
 *   3. Otherwise: fund externalUser with ~0.025 MNT for gas, mint 10 USDC mock,
 *      approve registry, registerAgent(externalAgent, "external-smoke-1", externalUser).
 *   4. Assert: AgentRegistered event emitted, agentIdOf[externalAgent] > 10,
 *      AgentInfo.active == true, AgentInfo.owner == externalUser, stake locked.
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
  blockExplorers: { default: { name: 'Mantlescan', url: 'https://sepolia.mantlescan.xyz' } },
});

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
  'function getAgent(uint256 agentId) view returns ((address agent, address owner, string name, uint256 stake, uint64 registeredAt, uint64 lastActiveAt, bool active))',
  'event AgentRegistered(uint256 indexed agentId, address indexed agent, address indexed owner, string name, uint256 stake)',
]);

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

function deriveKey(seed: string, label: string): Hex {
  const buf = createHash('sha256').update(`${seed}|MAPA-OPEN-REG|${label}`).digest();
  return `0x${buf.toString('hex')}` as Hex;
}

const USDC = (n: number) => BigInt(Math.round(n * 1e6));

async function main() {
  const t0 = Date.now();
  const rpcUrl = reqEnv('MANTLE_SEPOLIA_RPC_URL');
  const deployerPk = reqPk('DEPLOYER_PRIVATE_KEY');
  const seed = reqEnv('AGENTS_SEED');

  const usdcAddr = reqEnv('USDC_ADDRESS_SEPOLIA') as Address;
  const registryAddr = reqEnv('NEXT_PUBLIC_ARENA_REGISTRY_ADDRESS') as Address;

  const deployer = privateKeyToAccount(deployerPk);
  const externalUser = privateKeyToAccount(deriveKey(seed, 'EXTERNAL-USER'));
  const externalAgent = privateKeyToAccount(deriveKey(seed, 'EXTERNAL-AGENT-1'));

  const transport = http(rpcUrl);
  const pub = createPublicClient({ chain: mantleSepolia, transport });
  const wDeployer = createWalletClient({ chain: mantleSepolia, transport, account: deployer });
  const wUser = createWalletClient({ chain: mantleSepolia, transport, account: externalUser });

  console.log('━━━ MAPA open-registration smoke ━━━');
  console.log('Chain:         Mantle Sepolia (5003)');
  console.log('Registry:      ', registryAddr);
  console.log('USDC:          ', usdcAddr);
  console.log('Deployer:      ', deployer.address);
  console.log('External user: ', externalUser.address);
  console.log('External agent:', externalAgent.address);

  const stakeAmount = (await pub.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'stakeAmount',
  })) as bigint;
  console.log(`Stake required: ${formatUnits(stakeAmount, 6)} USDC`);

  // ── Idempotency: already registered? ──────────────────────
  const existing = (await pub.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'agentIdOf',
    args: [externalAgent.address],
  })) as bigint;
  if (existing > 0n) {
    const info = await pub.readContract({
      address: registryAddr, abi: registryAbi, functionName: 'getAgent',
      args: [existing],
    });
    if (!info.active) throw new Error(`agentId ${existing} not active`);
    if (info.owner.toLowerCase() !== externalUser.address.toLowerCase()) {
      throw new Error(`owner mismatch: on-chain ${info.owner} ≠ externalUser ${externalUser.address}`);
    }
    if (info.stake !== stakeAmount) {
      throw new Error(`stake mismatch: on-chain ${info.stake} ≠ ${stakeAmount}`);
    }
    console.log(`[skip ] external agent already registered as agentId=${existing}`);
    console.log(`        owner=${info.owner} active=${info.active} stake=${formatUnits(info.stake, 6)} USDC`);
    console.log('━━━ open-reg smoke PASS (idempotent skip) ━━━');
    console.log(`Wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
    return;
  }

  // ── Fund external user with MNT for gas ───────────────────
  // ~0.025 MNT covers: 1 mint + 1 approve + 1 registerAgent at Mantle Sepolia gas prices.
  const minGas = 20_000_000_000_000_000n; // 0.020 MNT
  const topUpTarget = 25_000_000_000_000_000n; // 0.025 MNT
  const userMnt = await pub.getBalance({ address: externalUser.address });
  console.log(`External user MNT balance: ${formatEther(userMnt)}`);
  if (userMnt < minGas) {
    const send = topUpTarget - userMnt;
    console.log(`Funding external user with ${formatEther(send)} MNT from deployer ...`);
    const hash = await wDeployer.sendTransaction({ to: externalUser.address, value: send });
    await pub.waitForTransactionReceipt({ hash });
    console.log(`    fund tx: ${hash}`);
  }

  // ── Mint mock USDC to external user (public mint) ─────────
  const userUsdc = (await pub.readContract({
    address: usdcAddr, abi: mockUsdcAbi, functionName: 'balanceOf', args: [externalUser.address],
  })) as bigint;
  if (userUsdc < stakeAmount) {
    console.log(`Minting ${formatUnits(stakeAmount, 6)} mock USDC to external user ...`);
    const hash = await wUser.writeContract({
      address: usdcAddr, abi: mockUsdcAbi, functionName: 'mint',
      args: [externalUser.address, stakeAmount],
    });
    await pub.waitForTransactionReceipt({ hash });
    console.log(`    mint tx: ${hash}`);
  }

  // ── Approve registry to pull stake ────────────────────────
  const allowance = (await pub.readContract({
    address: usdcAddr, abi: mockUsdcAbi, functionName: 'allowance',
    args: [externalUser.address, registryAddr],
  })) as bigint;
  if (allowance < stakeAmount) {
    console.log(`Approving registry for ${formatUnits(stakeAmount, 6)} USDC from external user ...`);
    const hash = await wUser.writeContract({
      address: usdcAddr, abi: mockUsdcAbi, functionName: 'approve',
      args: [registryAddr, stakeAmount],
    });
    await pub.waitForTransactionReceipt({ hash });
    console.log(`    approve tx: ${hash}`);
  }

  // ── Pre-register snapshot ─────────────────────────────────
  const beforeNextId = (await pub.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'nextAgentId',
  })) as bigint;
  console.log(`Pre-register nextAgentId = ${beforeNextId}`);
  if (beforeNextId <= 10n) {
    throw new Error(`expected nextAgentId > 10 (10 seeded), got ${beforeNextId} — re-run seed first`);
  }

  // ── Register from external EOA ────────────────────────────
  console.log('registerAgent(externalAgent, "external-smoke-1", externalUser) from externalUser ...');
  const hash = await wUser.writeContract({
    address: registryAddr, abi: registryAbi, functionName: 'registerAgent',
    args: [externalAgent.address, 'external-smoke-1', externalUser.address],
  });
  const receipt = await pub.waitForTransactionReceipt({ hash });
  const evts = parseEventLogs({
    abi: registryAbi, logs: receipt.logs, eventName: 'AgentRegistered',
  });
  if (evts.length !== 1) throw new Error(`AgentRegistered expected 1, got ${evts.length}`);
  const ev = evts[0];
  console.log(`    register tx: ${hash}`);
  console.log(`    event: agentId=${ev.args.agentId} agent=${ev.args.agent} owner=${ev.args.owner} stake=${formatUnits(ev.args.stake, 6)}`);

  // ── Post-register assertions ──────────────────────────────
  const agentId = ev.args.agentId;
  if (agentId <= 10n) {
    throw new Error(`agentId ${agentId} must be > 10 (after seed)`);
  }
  if (ev.args.agent.toLowerCase() !== externalAgent.address.toLowerCase()) {
    throw new Error(`event agent mismatch: ${ev.args.agent} ≠ ${externalAgent.address}`);
  }
  if (ev.args.owner.toLowerCase() !== externalUser.address.toLowerCase()) {
    throw new Error(`event owner mismatch: ${ev.args.owner} ≠ ${externalUser.address}`);
  }
  if (ev.args.stake !== stakeAmount) {
    throw new Error(`event stake mismatch: ${ev.args.stake} ≠ ${stakeAmount}`);
  }

  const onchainId = (await pub.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'agentIdOf',
    args: [externalAgent.address],
  })) as bigint;
  if (onchainId !== agentId) {
    throw new Error(`agentIdOf readback ${onchainId} ≠ event agentId ${agentId}`);
  }

  const info = await pub.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'getAgent',
    args: [agentId],
  });
  if (!info.active) throw new Error('agent.active == false after register');
  if (info.owner.toLowerCase() !== externalUser.address.toLowerCase()) {
    throw new Error(`getAgent owner mismatch: ${info.owner} ≠ ${externalUser.address}`);
  }
  if (info.stake !== stakeAmount) {
    throw new Error(`getAgent stake mismatch: ${info.stake} ≠ ${stakeAmount}`);
  }

  console.log('━━━ open-reg smoke PASS ━━━');
  console.log(`agentId=${agentId} stake=${formatUnits(info.stake, 6)} USDC owner=${info.owner}`);
  console.log(`tx: https://sepolia.mantlescan.xyz/tx/${hash}`);
  console.log(`Wall time: ${((Date.now() - t0) / 1000).toFixed(1)}s`);
}

main().catch((e) => {
  console.error('━━━ open-reg smoke FAIL ━━━');
  console.error(e);
  process.exit(1);
});
