/**
 * Read-only pre-flight check for Phase A2.
 * Prints MNT balances of deployer + judge, USDC balance of deployer, adapter.judge
 * wiring, and the 10 deterministic agent addresses derived from AGENTS_SEED.
 * Does NOT send any transactions.
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  defineChain,
  formatEther,
  formatUnits,
  http,
  parseAbi,
  type Address,
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

const SLUGS = [
  'claude-sonnet-strategist',
  'gpt54mini-arb',
  'claude-haiku-quant',
  'gemini-pro-macro',
  'mistral-small-swing',
  'deepseek-momentum',
  'llama4-scout-trend',
  'qwen36-meanrev',
  'phi4-contrarian',
  'gemini-flash-trend',
];

function reqEnv(name: string): string {
  const v = process.env[name];
  if (!v || v.trim() === '') throw new Error(`Missing env var: ${name}`);
  return v.trim();
}

function deriveAddress(seed: string, slug: string): Address {
  const buf = createHash('sha256').update(`${seed}|MAPA|${slug}`).digest();
  return privateKeyToAccount(`0x${buf.toString('hex')}`).address;
}

async function main() {
  const rpcUrl = reqEnv('MANTLE_SEPOLIA_RPC_URL');
  const seed = reqEnv('AGENTS_SEED');

  const deployerPkRaw = reqEnv('DEPLOYER_PRIVATE_KEY');
  const judgePkRaw = reqEnv('JUDGE_PRIVATE_KEY');
  const deployer = privateKeyToAccount(
    (deployerPkRaw.startsWith('0x') ? deployerPkRaw : `0x${deployerPkRaw}`) as `0x${string}`,
  );
  const judge = privateKeyToAccount(
    (judgePkRaw.startsWith('0x') ? judgePkRaw : `0x${judgePkRaw}`) as `0x${string}`,
  );

  const usdcAddr = reqEnv('USDC_ADDRESS_SEPOLIA') as Address;
  const registryAddr = reqEnv('NEXT_PUBLIC_ARENA_REGISTRY_ADDRESS') as Address;
  const adapterAddr = reqEnv('NEXT_PUBLIC_ERC8004_ADAPTER_ADDRESS') as Address;

  const client = createPublicClient({ chain: mantleSepolia, transport: http(rpcUrl) });

  const [deployerMnt, judgeMnt] = await Promise.all([
    client.getBalance({ address: deployer.address }),
    client.getBalance({ address: judge.address }),
  ]);

  const usdcAbi = parseAbi([
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address,address) view returns (uint256)',
  ]);
  const [usdcBal, usdcAllow] = await Promise.all([
    client.readContract({ address: usdcAddr, abi: usdcAbi, functionName: 'balanceOf', args: [deployer.address] }) as Promise<bigint>,
    client.readContract({ address: usdcAddr, abi: usdcAbi, functionName: 'allowance', args: [deployer.address, registryAddr] }) as Promise<bigint>,
  ]);

  const adapterAbi = parseAbi(['function judge() view returns (address)']);
  const adapterJudge = (await client.readContract({
    address: adapterAddr, abi: adapterAbi, functionName: 'judge',
  })) as Address;

  const registryAbi = parseAbi([
    'function stakeAmount() view returns (uint256)',
    'function nextAgentId() view returns (uint256)',
    'function agentIdOf(address) view returns (uint256)',
  ]);
  const [stake, nextId] = await Promise.all([
    client.readContract({ address: registryAddr, abi: registryAbi, functionName: 'stakeAmount' }) as Promise<bigint>,
    client.readContract({ address: registryAddr, abi: registryAbi, functionName: 'nextAgentId' }) as Promise<bigint>,
  ]);

  console.log('━━━ MAPA A2 pre-flight ━━━');
  console.log('Deployer EOA:        ', deployer.address);
  console.log('Deployer MNT:        ', formatEther(deployerMnt));
  console.log('Deployer USDC:       ', formatUnits(usdcBal, 6));
  console.log('Deployer→Registry  : ', formatUnits(usdcAllow, 6), 'USDC allowance');
  console.log('Judge EOA:           ', judge.address);
  console.log('Judge MNT:           ', formatEther(judgeMnt));
  console.log('Adapter.judge:       ', adapterJudge, adapterJudge.toLowerCase() === judge.address.toLowerCase() ? '✓ matches' : '✗ MISMATCH');
  console.log('Registry stakeAmount:', formatUnits(stake, 6), 'USDC');
  console.log('Registry nextAgentId:', nextId.toString());
  console.log('Required stake:      ', formatUnits(stake * BigInt(SLUGS.length), 6), 'USDC total');
  console.log('');
  console.log('Derived agent addresses (deterministic from AGENTS_SEED):');

  for (const slug of SLUGS) {
    const addr = deriveAddress(seed, slug);
    const id = (await client.readContract({
      address: registryAddr, abi: registryAbi, functionName: 'agentIdOf', args: [addr],
    })) as bigint;
    console.log(`  ${slug.padEnd(28)} ${addr}  ${id > 0n ? `(already id=${id})` : '(unregistered)'}`);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
