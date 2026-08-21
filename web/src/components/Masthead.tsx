"use client";

import { bpsToPercent, formatUnits } from "@/lib/format";
import {
  useCollateralRatio,
  useOnChainScore,
  usePosition,
  useProtocolState,
  useRiskCurve,
} from "@/lib/karma";
import type { ScoreResponse } from "@/lib/signer";

import { Figure, Mono, Tag } from "./Primitives";
import styles from "./Masthead.module.css";

/**
 * The first thing on screen is state, not a headline.
 *
 * With a wallet connected it is that wallet's score, ratio and borrowing power,
 * read from the chain. Without one it is the protocol's own numbers. There is
 * no version of this strip that shows marketing copy.
 */
export function Masthead({
  address,
  scored,
}: {
  address?: `0x${string}`;
  scored: ScoreResponse | null;
}) {
  const onChain = useOnChainScore(address);
  const position = usePosition(address);
  const protocol = useProtocolState();
  const curve = useRiskCurve();

  const hasOnChainScore = onChain.hasAttestation && onChain.valid;
  // Priced by the contract, not by the service. This is also what keeps the
  // figure correct for a wallet attested in an earlier session, where there is
  // no service response on screen at all.
  const onChainRatio = useCollateralRatio(hasOnChainScore ? onChain.score : undefined);

  if (!address) {
    return (
      <header className={styles.masthead}>
        <div className={styles.figures}>
          <Figure
            label="Pool liquidity"
            value={formatUnits(protocol.liquidity, 6, 0)}
            unit="kUSDC"
            hint="available to borrow right now"
          />
          <Figure
            label="Outstanding debt"
            value={formatUnits(protocol.totalDebt, 6, 0)}
            unit="kUSDC"
            hint="principal plus accrued interest"
          />
          <Figure
            label="Collateral range"
            value={
              curve.ratioAtMinScore
                ? `${bpsToPercent(curve.ratioAtMinScore)} → ${bpsToPercent(curve.ratioAtMaxScore)}`
                : "—"
            }
            hint="score 300 → 900, read from RiskParams"
          />
        </div>
        <p className={styles.state}>
          No wallet connected. These are the protocol&rsquo;s live figures, read from the
          contracts. Connect a wallet to see what it would be offered.
        </p>
      </header>
    );
  }

  return (
    <header className={styles.masthead}>
      <div className={styles.figures}>
        <Figure
          label="Credit score"
          value={hasOnChainScore ? onChain.score : (scored?.score ?? "—")}
          unit={hasOnChainScore ? "on chain" : scored ? "unverified" : undefined}
          tone={hasOnChainScore ? "ink" : "faint"}
          hint={
            hasOnChainScore
              ? "stored by ScoreOracle after signature recovery"
              : scored
                ? "signed by the service, not yet accepted by the contract"
                : "no attestation yet"
          }
        />
        <Figure
          label="Collateral ratio"
          value={
            hasOnChainScore && onChainRatio.data !== undefined
              ? bpsToPercent(onChainRatio.data as bigint)
              : scored
                ? bpsToPercent(scored.collateral_ratio_bps)
                : "—"
          }
          tone={hasOnChainScore ? "ink" : "faint"}
          hint={
            hasOnChainScore
              ? "priced by RiskParams from the stored score"
              : scored
                ? "indicative, not yet accepted on chain"
                : "no attestation yet"
          }
        />
        <Figure
          label="Borrowing power"
          value={formatUnits(position.maxBorrowable, 6, 2)}
          unit="kUSDC"
          tone={position.maxBorrowable && position.maxBorrowable > 0n ? "ink" : "faint"}
          hint="what LendingPool would lend against current collateral"
        />
      </div>

      <div className={styles.status}>
        {!onChain.hasAttestation ? (
          <Tag tone="warn">no attestation on chain</Tag>
        ) : !onChain.valid ? (
          <Tag tone="neg">attestation expired</Tag>
        ) : (
          <Tag tone="accent">verified on chain</Tag>
        )}
        {position.isLiquidatable ? <Tag tone="neg">liquidatable</Tag> : null}
        {onChain.attestation?.signer ? (
          <Mono size="xs" tone="faint">
            signer {onChain.attestation.signer.slice(0, 10)}…
          </Mono>
        ) : null}
      </div>
    </header>
  );
}
