/**
 * Read-only verification of Phase A2 success criteria:
 *   - 10 agents present in ArenaRegistry with correct slugs + active flag
 *   - MockReputation.getElo returns expected initial Elo
 *   - No agentId gaps (nextAgentId == 11)
 *
 * Does NOT check ERC-8004 mirror (bonus path, blocked by ID-space collision — see plan).
 */

import { config as dotenvConfig } from 'dotenv';
import {
  createPublicClient,
  defineChain,
  http,
  parseAbi,
  type Address,
} from 'viem';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenvConfig({ path: resolve(__dirname, '../../.env.local') });

const mantleSepolia = defineChain({
  id: 5003,
  name: 'Mantle Sepolia Testnet',
  nativeCurrency: { decimals: 18, name: 'Mantle', symbol: 'MNT' },
  rpcUrls: { default: { http: ['https://rpc.sepolia.mantle.xyz'] } },
});

interface Manifest {
  agents: { agentId: number; slug: string; initialElo: number; agentAddress: Address }[];
}

async function main() {
  const rpc = process.env.MANTLE_SEPOLIA_RPC_URL!;
  const registryAddr = process.env.NEXT_PUBLIC_ARENA_REGISTRY_ADDRESS! as Address;
  const reputationAddr = process.env.NEXT_PUBLIC_MOCK_REPUTATION_ADDRESS! as Address;

  const manifest: Manifest = JSON.parse(
    readFileSync(resolve(__dirname, '../data/agents.json'), 'utf-8'),
  );

  const client = createPublicClient({ chain: mantleSepolia, transport: http(rpc) });

  const registryAbi = parseAbi([
    'struct AgentInfo { address agent; address owner; string name; uint256 stake; uint64 registeredAt; uint64 lastActiveAt; bool active; }',
    'function getAgent(uint256) view returns (AgentInfo)',
    'function isActive(uint256) view returns (bool)',
    'function nextAgentId() view returns (uint256)',
  ]);
  const repAbi = parseAbi(['function getElo(uint256) view returns (uint256)']);

  const nextId = (await client.readContract({
    address: registryAddr, abi: registryAbi, functionName: 'nextAgentId',
  })) as bigint;
  console.log(`Registry.nextAgentId = ${nextId} (expect 11)`);
  if (nextId !== 11n) throw new Error('nextAgentId mismatch');

  let pass = 0;
  for (const a of manifest.agents) {
    const info = (await client.readContract({
      address: registryAddr, abi: registryAbi, functionName: 'getAgent', args: [BigInt(a.agentId)],
    })) as {
      agent: Address; owner: Address; name: string; stake: bigint;
      registeredAt: bigint; lastActiveAt: bigint; active: boolean;
    };

    const elo = (await client.readContract({
      address: reputationAddr, abi: repAbi, functionName: 'getElo', args: [BigInt(a.agentId)],
    })) as bigint;

    const ok =
      info.agent.toLowerCase() === a.agentAddress.toLowerCase()
      && info.name === a.slug
      && info.active === true
      && info.stake === 10_000_000n
      && elo === BigInt(a.initialElo);

    console.log(
      `  [${a.agentId}] ${a.slug.padEnd(28)} elo=${elo} active=${info.active} stake=${info.stake}  ${ok ? '✓' : '✗'}`,
    );
    if (ok) pass += 1;
  }

  console.log(`\nResult: ${pass}/${manifest.agents.length} agents fully verified`);
  if (pass !== manifest.agents.length) process.exit(1);
}

main().catch((e) => { console.error(e); process.exit(1); });
