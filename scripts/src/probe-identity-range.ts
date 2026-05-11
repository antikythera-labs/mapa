/**
 * Check agentIds 1..15 in real ERC-8004 IdentityRegistry on Sepolia.
 * Confirms whether our internal IDs collide with already-registered agents.
 */

import { config as dotenvConfig } from 'dotenv';
import { createPublicClient, defineChain, http, parseAbi, type Address } from 'viem';
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

async function main() {
  const rpc = process.env.MANTLE_SEPOLIA_RPC_URL!;
  const identityAddr = process.env.ERC_8004_IDENTITY_SEPOLIA! as Address;
  const client = createPublicClient({ chain: mantleSepolia, transport: http(rpc) });
  const abi = parseAbi(['function ownerOf(uint256) view returns (address)']);

  console.log('agentId → ownerOf in real ERC-8004 IdentityRegistry:');
  for (let i = 1n; i <= 15n; i++) {
    try {
      const o = await client.readContract({
        address: identityAddr, abi, functionName: 'ownerOf', args: [i],
      });
      console.log(`  ${String(i).padStart(3)} → ${o}`);
    } catch {
      console.log(`  ${String(i).padStart(3)} → (revert: no owner / out of range)`);
    }
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
