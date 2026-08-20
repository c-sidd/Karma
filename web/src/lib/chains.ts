import { defineChain } from "viem";
import { sepolia } from "viem/chains";

/** Local Foundry node. Present so the whole demo runs with no testnet ETH. */
export const anvil = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export { sepolia };

export const DEFAULT_CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? 31337);

/** Where a transaction can be looked up. Anvil has no explorer, and saying so
 *  is better than rendering a link that goes nowhere. */
export function explorerTxUrl(chainId: number, hash: string): string | null {
  if (chainId === sepolia.id) return `https://sepolia.etherscan.io/tx/${hash}`;
  return null;
}

export function explorerAddressUrl(chainId: number, address: string): string | null {
  if (chainId === sepolia.id) return `https://sepolia.etherscan.io/address/${address}`;
  return null;
}

export function chainName(chainId: number): string {
  if (chainId === sepolia.id) return "Sepolia";
  if (chainId === anvil.id) return "Anvil";
  return `Chain ${chainId}`;
}
