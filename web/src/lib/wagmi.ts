import { http, createConfig } from "wagmi";
import { injected } from "wagmi/connectors";

import { anvil, sepolia } from "./chains";

/**
 * Injected connector only.
 *
 * WalletConnect would need a cloud project id, which means an account. Karma is
 * meant to run end to end with no signups, so the browser wallet is the only
 * transport and the UI says so plainly when none is present.
 */
export const wagmiConfig = createConfig({
  chains: [anvil, sepolia],
  connectors: [injected()],
  transports: {
    [anvil.id]: http("http://127.0.0.1:8545"),
    [sepolia.id]: http(process.env.NEXT_PUBLIC_SEPOLIA_RPC_URL ?? "https://rpc.sepolia.org"),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
