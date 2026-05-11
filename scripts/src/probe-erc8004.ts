/**
 * Probe why ERC8004ReputationAdapter.mirrorElo reverted in seed-agents.
 * Hypotheses to check:
 *   H1: ERC-8004 Reputation requires agentId to exist in IdentityRegistry first.
 *   H2: ABI shape of giveFeedback differs from our adapter's assumption.
 *   H3: Some other check (rate limit, identity, etc.) blocks unknown agents.
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  defineChain,
  http,
  parseAbi,
  BaseError,
  ContractFunctionRevertedError,
  type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
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

function req(n: string) { const v = process.env[n]; if (!v) throw new Error(n); return v.trim(); }

async function main() {
  const rpc = req('MANTLE_SEPOLIA_RPC_URL');
  const judgePk = req('JUDGE_PRIVATE_KEY');
  const identityAddr = req('ERC_8004_IDENTITY_SEPOLIA') as Address;
  const reputationAddr = req('ERC_8004_REPUTATION_SEPOLIA') as Address;
  const adapterAddr = req('NEXT_PUBLIC_ERC8004_ADAPTER_ADDRESS') as Address;

  const judge = privateKeyToAccount((judgePk.startsWith('0x') ? judgePk : `0x${judgePk}`) as `0x${string}`);
  const client = createPublicClient({ chain: mantleSepolia, transport: http(rpc) });

  // ── Probe 1: does agentId 1 exist in ERC-8004 IdentityRegistry?
  //    Common ERC-8004 identity ABI exposes ownerOf / agentExists / getAgent (varies).
  console.log('━━━ ERC-8004 probe ━━━');
  console.log('Identity:  ', identityAddr);
  console.log('Reputation:', reputationAddr);
  console.log('Adapter:   ', adapterAddr);
  console.log('Judge:     ', judge.address);
  console.log('');

  const identityProbes = [
    'function ownerOf(uint256) view returns (address)',
    'function totalSupply() view returns (uint256)',
    'function agentCount() view returns (uint256)',
    'function getAgent(uint256) view returns (address,address)',
    'function nextAgentId() view returns (uint256)',
  ];

  for (const sig of identityProbes) {
    const abi = parseAbi([sig]);
    const fname = sig.match(/function (\w+)/)![1];
    try {
      let args: unknown[] = [];
      if (sig.includes('(uint256)')) args = [1n];
      const result = await client.readContract({
        address: identityAddr, abi, functionName: fname, args: args as never,
      });
      console.log(`identity.${fname}${args.length ? '(1)' : '()'} =`, result);
    } catch (e) {
      const msg = (e as BaseError).shortMessage ?? (e as Error).message;
      console.log(`identity.${fname} → revert / not found: ${msg.split('\n')[0]}`);
    }
  }

  // ── Probe 2: try simulating mirrorElo to capture revert reason
  console.log('');
  console.log('Simulating adapter.mirrorElo(1, 1900) from judge ...');
  const adapterAbi = parseAbi(['function mirrorElo(uint256 agentId, int128 elo)']);
  try {
    await client.simulateContract({
      address: adapterAddr, abi: adapterAbi, functionName: 'mirrorElo',
      args: [1n, 1900n],
      account: judge,
    });
    console.log('simulateContract: would succeed (unexpected)');
  } catch (e) {
    const be = e as BaseError;
    const walk = be.walk?.((err) => err instanceof ContractFunctionRevertedError) as
      | ContractFunctionRevertedError
      | undefined;
    if (walk) {
      console.log('Revert data:', walk.data);
      console.log('Revert reason:', walk.reason);
      console.log('Revert errorName:', walk.data?.errorName);
      console.log('Revert args:', walk.data?.args);
    } else {
      console.log('Short message:', be.shortMessage);
      console.log('Full (first 400):', String(be).slice(0, 400));
    }
  }

  // ── Probe 3: direct giveFeedback from EOA judge — see if adapter wrapping matters
  console.log('');
  console.log('Simulating reputation.giveFeedback(1, 1900, 0, "MAPA-Elo", "v1") direct from judge ...');
  const repAbi = parseAbi([
    'function giveFeedback(uint256 agentId, int128 feedbackValue, uint8 authType, bytes32 tag1, bytes32 tag2)',
  ]);
  const tag1 = '0x4d4150412d456c6f0000000000000000000000000000000000000000000000' + '00';
  const tag2 = '0x76310000000000000000000000000000000000000000000000000000000000' + '00';
  try {
    await client.simulateContract({
      address: reputationAddr, abi: repAbi, functionName: 'giveFeedback',
      args: [1n, 1900n, 0, tag1 as `0x${string}`, tag2 as `0x${string}`],
      account: judge,
    });
    console.log('simulate: would succeed (unexpected)');
  } catch (e) {
    const be = e as BaseError;
    const walk = be.walk?.((err) => err instanceof ContractFunctionRevertedError) as
      | ContractFunctionRevertedError
      | undefined;
    if (walk) {
      console.log('Revert data:', walk.data);
      console.log('Revert reason:', walk.reason);
    } else {
      console.log('Short message:', be.shortMessage);
      console.log('Full (first 400):', String(be).slice(0, 400));
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
