"use client";

import { formatFeatureValue } from "@/lib/format";
import type { ScoreResponse } from "@/lib/signer";

import { Mono, Panel, Tag } from "./Primitives";
import styles from "./ScoreBreakdown.module.css";

/**
 * The eight features and what each one did to this wallet's score.
 *
 * Contributions come from the model, by leave-one-out ablation against the
 * training median: the feature is replaced by its median, the wallet is
 * re-scored, and the difference in points is the contribution. That is a real
 * measurement rather than a weight read off the model, and it is not SHAP, so
 * the eight numbers do not sum exactly to anything. The panel says so.
 */
export function ScoreBreakdown({ scored }: { scored: ScoreResponse | null }) {
  if (!scored) {
    return (
      <Panel id="score" title="Score breakdown">
        <p className={styles.empty}>
          Request a signed score to see which parts of the wallet&rsquo;s history moved it, and
          by how many points.
        </p>
      </Panel>
    );
  }

  const peak = Math.max(1, ...scored.features.map((f) => Math.abs(f.contribution)));
  const anyReal = scored.feature_provenance.real_features.length > 0;

  return (
    <Panel
      id="score"
      title="Score breakdown"
      aside={
        <>
          <Mono size="xs" tone="faint">
            P(default) {scored.probability_of_default.toFixed(5)}
          </Mono>
          <Tag tone="warn">
            {anyReal
              ? `${scored.feature_provenance.real_features.length}/8 from chain`
              : "all synthetic"}
          </Tag>
        </>
      }
    >
      <table className="tabular">
        <thead>
          <tr>
            <th className={styles.colName}>Feature</th>
            <th className={styles.colValue}>Value</th>
            <th className={styles.colBaseline}>Median</th>
            <th className={styles.colSource}>Source</th>
            <th className={styles.colBar}>Contribution to score</th>
            <th className={styles.colPoints}>Points</th>
          </tr>
        </thead>
        <tbody>
          {scored.features.map((f) => {
            const width = (Math.abs(f.contribution) / peak) * 100;
            const positive = f.contribution >= 0;
            return (
              <tr key={f.name}>
                <td className={styles.name}>{f.name}</td>
                <td className="num">
                  <Mono size="sm">{formatFeatureValue(f.value)}</Mono>
                </td>
                <td className="num">
                  <Mono size="xs" tone="faint">
                    {formatFeatureValue(f.baseline)}
                  </Mono>
                </td>
                <td>
                  <Tag tone={f.source === "chain" ? "pos" : "warn"}>{f.source}</Tag>
                </td>
                <td className={styles.barCell}>
                  <div className={styles.axis}>
                    <div
                      className={positive ? styles.barPos : styles.barNeg}
                      style={{ width: `${width / 2}%` }}
                    />
                  </div>
                </td>
                <td className="num">
                  <Mono size="sm" tone={positive ? "pos" : "neg"}>
                    {f.contribution >= 0 ? "+" : ""}
                    {f.contribution.toFixed(0)}
                  </Mono>
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>

      <div className={styles.footnotes}>
        <p className={styles.footnote}>
          Contribution is the score change from replacing that one feature with its training
          median and re-scoring. Directional and reproducible, not additive: these are not SHAP
          values and they do not sum to the distance from a baseline score.
        </p>
        {scored.feature_provenance.warning ? (
          <p className={styles.warning}>{scored.feature_provenance.warning}</p>
        ) : null}
        <p className={styles.footnote}>
          featureHash <Mono size="xs">{scored.feature_hash}</Mono> commits the signer to exactly
          these values. It is carried inside the signature, so the numbers above cannot be
          swapped after the fact.
        </p>
      </div>
    </Panel>
  );
}
