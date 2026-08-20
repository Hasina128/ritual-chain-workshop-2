import { createConfig, http } from "wagmi";
import { defineChain } from "viem";
import { injected } from "wagmi/connectors";
import type { Address } from "viem";

export const chainId = Number(process.env.NEXT_PUBLIC_RITUAL_CHAIN_ID ?? "1979");
export const rpc =
  process.env.NEXT_PUBLIC_RITUAL_RPC_URL ?? "https://rpc.ritualfoundation.org";

const raw = process.env.NEXT_PUBLIC_PREDICT_ADDRESS?.trim();
export const deskAddress: Address | undefined =
  raw && /^0x[0-9a-fA-F]{40}$/.test(raw) ? (raw as Address) : undefined;

export const faucet = "https://faucet.ritualfoundation.org";
export const explorer = "https://explorer.ritualfoundation.org";
export const feedHint = process.env.NEXT_PUBLIC_DEMO_ORACLE_URL?.trim() ?? "";

export const ritual = defineChain({
  id: chainId,
  name: "Ritual",
  nativeCurrency: { name: "Ritual", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } },
  blockExplorers: { default: { name: "scan", url: explorer } },
});

export const wagmiConfig = createConfig({
  chains: [ritual],
  connectors: [injected({ shimDisconnect: true })],
  ssr: true,
  transports: { [ritual.id]: http(rpc) },
});
