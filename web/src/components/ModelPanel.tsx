"use client";

import { bpsToPercent } from "@/lib/format";
import type { ModelReport } from "@/lib/signer";

import { Mono, Panel, Tag } from "./Primitives";
import styles from "./ModelPanel.module.css";

/**
 * The model's own report card, served by the signer service from
 * model/artifacts/model_report.json. Nothing here is typed into the UI by hand.
 */
export function ModelPanel({
  report,
  error,
  loading,
}: {
  report: ModelReport | null;
  error: string | null;
  loading: boolean;
}) {
  if (loading) {
    return (
      <Panel id="model" title="Model">
        <div className={styles.skeleton}>
          {[0, 1, 2, 3].map((i) => (
            <div key={i} className={styles.skeletonRow} />
          ))}
        </div>
      </Panel>
    );
  }

  if (error || !report) {
    return (
      <Panel id="model" title="Model">
        <p className={styles.error}>
          {error ?? "No model report available."}{" "}
          <span className={styles.errorHint}>
            The report is served by the signer service. Start it with <code>make signer</code>.
          </span>
        </p>
      </Panel>
    );
  }

  const real = report.data_source.is_real_data === true;
  const bands = report.score_bands;
  const peak = Math.max(...bands.map((b) => b.default_rate ?? 0), 0.0001);

  return (
    <Panel
      id="model"
      title="Model"
      aside={
        <>
          <Mono size="xs" tone="faint">
            v{report.model_version}
          </Mono>
          <Tag tone={real ? "pos" : "warn"}>{real ? "real data" : "bootstrap data"}</Tag>
        </>
      }
    >
      {!real ? (
        <p className={styles.provenance}>
          <strong>{report.data_source.label}</strong> Every figure in this panel describes a
          simulation on generated wallets. The pipeline for real Aave v3 data is written and
          documented in <Mono size="xs">model/dune_queries.sql</Mono>, and has not been run
          here because it needs a Dune account.
        </p>
      ) : (
        <p className={styles.provenance}>
          <strong>{report.data_source.label}</strong>{" "}
          {report.data_source.query_url ? (
            <a href={report.data_source.query_url} target="_blank" rel="noreferrer">
              source query
            </a>
          ) : null}
        </p>
      )}

      <div className={styles.metrics}>
        {(
          [
            ["AUC (test)", report.metrics.auc_test],
            ["AUC (train)", report.metrics.auc_train],
            ["KS", report.metrics.ks_test],
            ["Brier", report.metrics.brier_test],
            ["Base default rate", report.dataset.base_default_rate],
            ["Test rows", report.dataset.n_test.toLocaleString("en-US")],
          ] as const
        ).map(([label, value]) => (
          <div key={label} className={styles.metric}>
            <span className="label">{label}</span>
            <Mono size="lg">{value}</Mono>
          </div>
        ))}
      </div>

      <div className={styles.bands}>
        <span className="label">Realised default rate by score band</span>
        <table className="tabular">
          <thead>
            <tr>
              <th>Band</th>
              <th className={styles.right}>Wallets</th>
              <th className={styles.right}>Default rate</th>
              <th className={styles.bar}>&nbsp;</th>
              <th className={styles.right}>Collateral required</th>
            </tr>
          </thead>
          <tbody>
            {bands.map((b) => (
              <tr key={b.band}>
                <td>
                  <Mono size="sm">{b.band}</Mono>
                </td>
                <td className="num">
                  <Mono size="sm" tone="muted">
                    {b.n.toLocaleString("en-US")}
                  </Mono>
                </td>
                <td className="num">
                  <Mono size="sm">
                    {b.default_rate === null ? "—" : `${(b.default_rate * 100).toFixed(2)}%`}
                  </Mono>
                </td>
                <td>
                  <div className={styles.track}>
                    <div
                      className={styles.fill}
                      style={{ width: `${((b.default_rate ?? 0) / peak) * 100}%` }}
                    />
                  </div>
                </td>
                <td className="num">
                  <Mono size="sm" tone="muted">
                    {bpsToPercent(b.collateral_ratio_bps)}
                  </Mono>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
        <p className={styles.note}>
          The rate falls monotonically as the score rises. That is the property that makes the
          score usable for pricing; a good AUC alone would not.
        </p>
      </div>

      <div className={styles.efficiency}>
        <div>
          <span className="label">Collateral freed vs flat 150%</span>
          <Mono size="lg" tone="ink">
            {report.capital_efficiency.collateral_freed_pct}%
          </Mono>
        </div>
        <div>
          <span className="label">Borrowing power lift</span>
          <Mono size="lg" tone="ink">
            +{report.capital_efficiency.borrowing_power_lift_pct}%
          </Mono>
        </div>
        <p className={styles.note}>
          Measured across the held-out test population, against a protocol that asks every
          borrower for 150%.
        </p>
      </div>

      <div className={styles.importance}>
        <span className="label">Feature importance</span>
        <ul className={styles.importanceList}>
          {report.feature_importance.map((f) => (
            <li key={f.name} className={styles.importanceRow}>
              <span className={styles.importanceName}>{f.name}</span>
              <div className={styles.track}>
                <div
                  className={styles.fillQuiet}
                  style={{
                    width: `${(f.importance / (report.feature_importance[0]?.importance || 1)) * 100}%`,
                  }}
                />
              </div>
              <Mono size="xs" tone="muted">
                {f.importance.toFixed(3)}
              </Mono>
            </li>
          ))}
        </ul>
      </div>
    </Panel>
  );
}
