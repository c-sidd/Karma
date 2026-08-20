"use client";

import { useAccount, useChainId, useReadContract, useReadContracts } from "wagmi";

import { deployments, type Deployment } from "@/generated/deployments";
import { lendingpoolAbi, riskparamsAbi, scoreoracleAbi } from "@/generated/abis";
import { DEFAULT_CHAIN_ID } from "./chains";

export type { Deployment };

/** The deployment for the connected chain, or null when Karma is not there. */
export function useDeployment(): { deployment: Deployment | null; chainId: number } {
  const connectedChainId = useChainId();
  const chainId = connectedChainId || DEFAULT_CHAIN_ID;
  return { deployment: deployments[chainId] ?? null, chainId };
}

/** Pool-wide state. Rendered when no wallet is connected, so the first screen
 *  still shows real numbers instead of a marketing headline. */
export function useProtocolState() {
  const { deployment } = useDeployment();
  const pool = deployment?.LendingPool;

  const query = useReadContracts({
    contracts: pool
      ? ([
          { address: pool, abi: lendingpoolAbi, functionName: "availableLiquidity" },
          { address: pool, abi: lendingpoolAbi, functionName: "totalDebt" },
          { address: pool, abi: lendingpoolAbi, functionName: "maxBorrowPerWallet" },
          { address: pool, abi: lendingpoolAbi, functionName: "borrowIndex" },
          { address: pool, abi: lendingpoolAbi, functionName: "ratePerSecondWad" },
        ] as const)
      : [],
    query: { enabled: Boolean(pool), refetchInterval: 12_000 },
  });

  const [liquidity, totalDebt, borrowCap, borrowIndex, ratePerSecond] = query.data ?? [];
  return {
    ...query,
    liquidity: liquidity?.result as bigint | undefined,
    totalDebt: totalDebt?.result as bigint | undefined,
    borrowCap: borrowCap?.result as bigint | undefined,
    borrowIndex: borrowIndex?.result as bigint | undefined,
    ratePerSecond: ratePerSecond?.result as bigint | undefined,
  };
}

/** The curve endpoints, read from the chain rather than restated in the UI. */
export function useRiskCurve() {
  const { deployment } = useDeployment();
  const risk = deployment?.RiskParams;

  const query = useReadContracts({
    contracts: risk
      ? ([
          { address: risk, abi: riskparamsAbi, functionName: "ratioAtMinScore" },
          { address: risk, abi: riskparamsAbi, functionName: "ratioAtMaxScore" },
          { address: risk, abi: riskparamsAbi, functionName: "ABS_MIN_RATIO_BPS" },
        ] as const)
      : [],
    query: { enabled: Boolean(risk) },
  });

  const [atMin, atMax, floor] = query.data ?? [];
  return {
    ...query,
    ratioAtMinScore: atMin?.result as bigint | undefined,
    ratioAtMaxScore: atMax?.result as bigint | undefined,
    absMinRatioBps: floor?.result as bigint | undefined,
  };
}

/** What the oracle currently holds for a wallet. */
export function useOnChainScore(address?: `0x${string}`) {
  const { deployment } = useDeployment();
  const oracle = deployment?.ScoreOracle;

  const query = useReadContracts({
    contracts:
      oracle && address
        ? ([
            { address: oracle, abi: scoreoracleAbi, functionName: "scoreOf", args: [address] },
            {
              address: oracle,
              abi: scoreoracleAbi,
              functionName: "attestationOf",
              args: [address],
            },
          ] as const)
        : [],
    query: { enabled: Boolean(oracle && address) },
  });

  const [scoreOf, record] = query.data ?? [];
  const tuple = scoreOf?.result as readonly [number, boolean] | undefined;
  const attestation = record?.result as
    | {
        score: number;
        modelVersion: number;
        expiry: bigint;
        issuedAt: bigint;
        signer: `0x${string}`;
        featureHash: `0x${string}`;
      }
    | undefined;

  const hasAttestation = attestation !== undefined && attestation.expiry > 0n;

  return {
    ...query,
    score: tuple?.[0],
    valid: tuple?.[1] ?? false,
    hasAttestation,
    attestation,
  };
}

/** A borrower's position. */
export function usePosition(address?: `0x${string}`) {
  const { deployment } = useDeployment();
  const pool = deployment?.LendingPool;

  const query = useReadContracts({
    contracts:
      pool && address
        ? ([
            { address: pool, abi: lendingpoolAbi, functionName: "collateralOf", args: [address] },
            { address: pool, abi: lendingpoolAbi, functionName: "debtOf", args: [address] },
            {
              address: pool,
              abi: lendingpoolAbi,
              functionName: "currentRatioBps",
              args: [address],
            },
            {
              address: pool,
              abi: lendingpoolAbi,
              functionName: "maxBorrowable",
              args: [address],
            },
            {
              address: pool,
              abi: lendingpoolAbi,
              functionName: "liquidationDistanceBps",
              args: [address],
            },
            { address: pool, abi: lendingpoolAbi, functionName: "isLiquidatable", args: [address] },
          ] as const)
        : [],
    query: { enabled: Boolean(pool && address), refetchInterval: 12_000 },
  });

  const [collateral, debt, ratio, headroom, distance, liquidatable] = query.data ?? [];
  return {
    ...query,
    collateral: collateral?.result as bigint | undefined,
    debt: debt?.result as bigint | undefined,
    ratioBps: ratio?.result as bigint | undefined,
    maxBorrowable: headroom?.result as bigint | undefined,
    liquidationDistanceBps: distance?.result as bigint | undefined,
    isLiquidatable: (liquidatable?.result as boolean | undefined) ?? false,
  };
}

/** Whether the oracle recognises an address as a model signer. */
export function useIsModelSigner(signer?: `0x${string}`) {
  const { deployment } = useDeployment();
  return useReadContract({
    address: deployment?.ScoreOracle,
    abi: scoreoracleAbi,
    functionName: "isModelSigner",
    args: signer ? [signer] : undefined,
    query: { enabled: Boolean(deployment?.ScoreOracle && signer) },
  });
}

export function useConnectedAddress() {
  const { address, isConnected } = useAccount();
  return { address, isConnected };
}
