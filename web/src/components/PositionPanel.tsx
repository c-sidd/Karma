"use client";

import { useCallback, useState } from "react";
import { useReadContract, useWaitForTransactionReceipt, useWriteContract } from "wagmi";
import { parseUnits } from "viem";

import { faucettokenAbi, lendingpoolAbi } from "@/generated/abis";
import { explorerTxUrl } from "@/lib/chains";
import { decodeRevert, isUserRejection } from "@/lib/errors";
import { bpsToPercent, formatUnits, truncateAddress } from "@/lib/format";
import { useDeployment, useOnChainScore, usePosition } from "@/lib/karma";

import { Button, Mono, Panel, Row, Tag } from "./Primitives";
import styles from "./PositionPanel.module.css";

const COLLATERAL_DECIMALS = 18;
const DEBT_DECIMALS = 6;

export function PositionPanel({ address }: { address?: `0x${string}` }) {
  const { deployment, chainId } = useDeployment();
  const position = usePosition(address);
  const onChain = useOnChainScore(address);
  const { writeContractAsync, isPending } = useWriteContract();

  const [collateralInput, setCollateralInput] = useState("1");
  const [borrowInput, setBorrowInput] = useState("500");
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);

  const receipt = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
    query: { enabled: Boolean(txHash) },
  });

  const collateralBalance = useReadContract({
    address: deployment?.collateralAsset,
    abi: faucettokenAbi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: Boolean(deployment?.collateralAsset && address) },
  });

  const allowance = useReadContract({
    address: deployment?.collateralAsset,
    abi: faucettokenAbi,
    functionName: "allowance",
    args: address && deployment ? [address, deployment.LendingPool] : undefined,
    query: { enabled: Boolean(deployment && address) },
  });

  const run = useCallback(
    async (label: string, fn: () => Promise<`0x${string}`>) => {
      setError(null);
      setBusy(label);
      try {
        setTxHash(await fn());
      } catch (e) {
        if (!isUserRejection(e)) setError(decodeRevert(e).message);
      } finally {
        setBusy(null);
      }
    },
    []
  );

  if (!address) {
    return (
      <Panel id="position" title="Position">
        <p className={styles.empty}>
          No wallet connected. A position shows collateral posted, debt outstanding, the current
          ratio and how far that ratio sits above the liquidation threshold for this
          wallet&rsquo;s score.
        </p>
      </Panel>
    );
  }

  if (!deployment) {
    return (
      <Panel id="position" title="Position">
        <p className={styles.empty}>Karma is not deployed on this chain.</p>
      </Panel>
    );
  }

  const hasDebt = (position.debt ?? 0n) > 0n;
  const distance = position.liquidationDistanceBps;
  const distanceIsSafe = distance !== undefined && distance > 500n;

  return (
    <Panel
      id="position"
      title="Position"
      aside={
        position.isLiquidatable ? (
          <Tag tone="neg">liquidatable</Tag>
        ) : hasDebt ? (
          <Tag tone={distanceIsSafe ? "pos" : "warn"}>
            {distanceIsSafe ? "healthy" : "near threshold"}
          </Tag>
        ) : (
          <Tag>no debt</Tag>
        )
      }
    >
      <div className={styles.grid}>
        <div className={styles.readout}>
          <Row label="Collateral">
            <Mono size="md">{formatUnits(position.collateral, COLLATERAL_DECIMALS, 4)}</Mono>{" "}
            <Mono size="xs" tone="faint">
              kWETH
            </Mono>
          </Row>
          <Row label="Debt">
            <Mono size="md">{formatUnits(position.debt, DEBT_DECIMALS, 2)}</Mono>{" "}
            <Mono size="xs" tone="faint">
              kUSDC
            </Mono>
          </Row>
          <Row label="Current ratio">
            {hasDebt ? (
              <Mono size="md" tone={position.isLiquidatable ? "neg" : "ink"}>
                {bpsToPercent(position.ratioBps)}
              </Mono>
            ) : (
              <Mono size="md" tone="faint">
                ∞
              </Mono>
            )}
          </Row>
          <Row label="Liquidation distance">
            {hasDebt ? (
              <Mono size="md" tone={distanceIsSafe ? "pos" : "neg"}>
                {bpsToPercent(distance)}
              </Mono>
            ) : (
              <Mono size="md" tone="faint">
                —
              </Mono>
            )}
          </Row>
          <Row label="Headroom">
            <Mono size="md">{formatUnits(position.maxBorrowable, DEBT_DECIMALS, 2)}</Mono>{" "}
            <Mono size="xs" tone="faint">
              kUSDC
            </Mono>
          </Row>
          <Row label="Wallet balance">
            <Mono size="sm" tone="muted">
              {formatUnits(collateralBalance.data as bigint | undefined, COLLATERAL_DECIMALS, 4)}
            </Mono>{" "}
            <Mono size="xs" tone="faint">
              kWETH
            </Mono>
          </Row>
        </div>

        <div className={styles.actions}>
          {!onChain.valid ? (
            <p className={styles.gate}>
              <Tag tone="warn">borrow disabled</Tag> LendingPool.borrow() reverts without a live
              attestation. Verify and submit one above first — there is no path around this in
              the contract.
            </p>
          ) : null}

          <div className={styles.action}>
            <span className="label">Collateral</span>
            <div className={styles.controlRow}>
              <input
                className={styles.input}
                value={collateralInput}
                onChange={(e) => setCollateralInput(e.target.value)}
                inputMode="decimal"
                aria-label="collateral amount in kWETH"
              />
              <Button
                onClick={() =>
                  run("approve", () =>
                    writeContractAsync({
                      address: deployment.collateralAsset,
                      abi: faucettokenAbi,
                      functionName: "approve",
                      args: [
                        deployment.LendingPool,
                        parseUnits(collateralInput || "0", COLLATERAL_DECIMALS),
                      ],
                    })
                  )
                }
                disabled={isPending}
              >
                {busy === "approve" ? "…" : "Approve"}
              </Button>
              <Button
                onClick={() =>
                  run("deposit", () =>
                    writeContractAsync({
                      address: deployment.LendingPool,
                      abi: lendingpoolAbi,
                      functionName: "depositCollateral",
                      args: [parseUnits(collateralInput || "0", COLLATERAL_DECIMALS)],
                    })
                  )
                }
                disabled={isPending}
              >
                {busy === "deposit" ? "…" : "Deposit"}
              </Button>
              <Button
                variant="quiet"
                onClick={() =>
                  run("faucet", () =>
                    writeContractAsync({
                      address: deployment.collateralAsset,
                      abi: faucettokenAbi,
                      functionName: "drip",
                    })
                  )
                }
                disabled={isPending}
                title="Mint test collateral"
              >
                {busy === "faucet" ? "…" : "Faucet"}
              </Button>
            </div>
            <span className={styles.hint}>
              allowance{" "}
              <Mono size="xs" tone="faint">
                {formatUnits(allowance.data as bigint | undefined, COLLATERAL_DECIMALS, 2)}
              </Mono>
            </span>
          </div>

          <div className={styles.action}>
            <span className="label">Debt</span>
            <div className={styles.controlRow}>
              <input
                className={styles.input}
                value={borrowInput}
                onChange={(e) => setBorrowInput(e.target.value)}
                inputMode="decimal"
                aria-label="borrow amount in kUSDC"
              />
              <Button
                variant="primary"
                onClick={() =>
                  run("borrow", () =>
                    writeContractAsync({
                      address: deployment.LendingPool,
                      abi: lendingpoolAbi,
                      functionName: "borrow",
                      args: [parseUnits(borrowInput || "0", DEBT_DECIMALS)],
                    })
                  )
                }
                disabled={isPending || !onChain.valid}
              >
                {busy === "borrow" ? "…" : "Borrow"}
              </Button>
              <Button
                onClick={() =>
                  run("repay", () =>
                    writeContractAsync({
                      address: deployment.LendingPool,
                      abi: lendingpoolAbi,
                      functionName: "repay",
                      args: [address, parseUnits(borrowInput || "0", DEBT_DECIMALS)],
                    })
                  )
                }
                disabled={isPending || !hasDebt}
              >
                {busy === "repay" ? "…" : "Repay"}
              </Button>
            </div>
            <span className={styles.hint}>
              repaying needs a kUSDC approval to the pool first
            </span>
          </div>

          {txHash ? (
            <div className={styles.tx}>
              <Tag tone={receipt.data?.status === "success" ? "pos" : "neutral"}>
                {receipt.isLoading ? "pending" : (receipt.data?.status ?? "sent")}
              </Tag>
              <Mono size="xs" title={txHash}>
                {truncateAddress(txHash, 10, 8)}
              </Mono>
              {explorerTxUrl(chainId, txHash) ? (
                <a href={explorerTxUrl(chainId, txHash)!} target="_blank" rel="noreferrer">
                  <Mono size="xs">etherscan</Mono>
                </a>
              ) : (
                <Mono size="xs" tone="faint">
                  local chain — no explorer
                </Mono>
              )}
            </div>
          ) : null}

          {error ? (
            <div className={styles.error}>
              <Tag tone="neg">reverted</Tag>
              <Mono size="xs" tone="neg">
                {error}
              </Mono>
            </div>
          ) : null}
        </div>
      </div>
    </Panel>
  );
}
