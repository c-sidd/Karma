"use client";

import { useEffect, useState } from "react";
import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";

import { chainName, explorerAddressUrl } from "@/lib/chains";
import { useDeployment, useProtocolState } from "@/lib/karma";
import { bpsToPercent, formatUnits, truncateAddress } from "@/lib/format";
import { signerApi, type HealthResponse } from "@/lib/signer";

import { Mono, Tag } from "./Primitives";
import styles from "./Rail.module.css";

const SECTIONS = [
  { id: "verification", label: "Verification" },
  { id: "score", label: "Score breakdown" },
  { id: "position", label: "Position" },
  { id: "model", label: "Model" },
] as const;

export function Rail() {
  const { address, isConnected, connector } = useAccount();
  const { connect, connectors, isPending, error: connectError } = useConnect();
  const { disconnect } = useDisconnect();
  const { chains, switchChain } = useSwitchChain();
  const { deployment, chainId } = useDeployment();
  const protocol = useProtocolState();

  const [health, setHealth] = useState<HealthResponse | null>(null);
  const [healthError, setHealthError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    signerApi
      .health()
      .then((h) => !cancelled && setHealth(h))
      .catch((e: Error) => !cancelled && setHealthError(e.message));
    return () => {
      cancelled = true;
    };
  }, []);

  const injected = connectors[0];
  const explorer = address ? explorerAddressUrl(chainId, address) : null;

  return (
    <aside className={styles.rail}>
      <div className={styles.brand}>
        <span className={styles.wordmark}>KARMA</span>
        <span className={styles.tagline}>
          Collateral priced from a signed credit score. The signature is checked on chain
          before the loan is priced.
        </span>
      </div>

      {/* --- wallet ---------------------------------------------------- */}
      <div className={styles.block}>
        <span className="label">Wallet</span>
        {isConnected && address ? (
          <>
            <div className={styles.walletRow}>
              <Mono size="sm">{truncateAddress(address, 10, 8)}</Mono>
              <button className={styles.quiet} onClick={() => disconnect()}>
                disconnect
              </button>
            </div>
            <div className={styles.metaRow}>
              <Mono size="xs" tone="faint">
                {connector?.name ?? "injected"}
              </Mono>
              {explorer ? (
                <a href={explorer} target="_blank" rel="noreferrer" className={styles.link}>
                  <Mono size="xs" tone="faint">
                    etherscan
                  </Mono>
                </a>
              ) : null}
            </div>
          </>
        ) : (
          <>
            <button
              className={styles.connect}
              onClick={() => injected && connect({ connector: injected })}
              disabled={isPending || !injected}
            >
              {isPending ? "Waiting for wallet…" : "Connect wallet"}
            </button>
            <span className={styles.note}>
              {injected
                ? "Browser wallet only. No WalletConnect project id, so nothing here needs an account."
                : "No browser wallet detected. Install MetaMask or Rabby to transact; the panels below stay readable without one."}
            </span>
            {connectError ? (
              <span className={styles.errorNote}>{connectError.message}</span>
            ) : null}
          </>
        )}
      </div>

      {/* --- network --------------------------------------------------- */}
      <div className={styles.block}>
        <span className="label">Network</span>
        <div className={styles.walletRow}>
          <Mono size="sm">{chainName(chainId)}</Mono>
          <Mono size="xs" tone="faint">
            id {chainId}
          </Mono>
        </div>
        {!deployment ? (
          <span className={styles.errorNote}>
            Karma is not deployed on this chain. Switch network, or run
            <code> make deploy-local</code>.
          </span>
        ) : null}
        <div className={styles.chainSwitch}>
          {chains.map((c) => (
            <button
              key={c.id}
              className={`${styles.chip} ${c.id === chainId ? styles.chipActive : ""}`}
              onClick={() => switchChain({ chainId: c.id })}
              disabled={c.id === chainId}
            >
              {c.name}
            </button>
          ))}
        </div>
      </div>

      {/* --- contracts ------------------------------------------------- */}
      {deployment ? (
        <div className={styles.block}>
          <span className="label">Contracts</span>
          <dl className={styles.addresses}>
            {(
              [
                ["ScoreOracle", deployment.ScoreOracle],
                ["LendingPool", deployment.LendingPool],
                ["RiskParams", deployment.RiskParams],
                ["Model signer", deployment.modelSigner],
              ] as const
            ).map(([label, value]) => {
              const url = explorerAddressUrl(chainId, value);
              return (
                <div key={label} className={styles.addressRow}>
                  <dt className={styles.addressLabel}>{label}</dt>
                  <dd className={styles.addressValue}>
                    {url ? (
                      <a href={url} target="_blank" rel="noreferrer" className={styles.link}>
                        <Mono size="xs">{truncateAddress(value, 6, 4)}</Mono>
                      </a>
                    ) : (
                      <Mono size="xs" title={value}>
                        {truncateAddress(value, 6, 4)}
                      </Mono>
                    )}
                  </dd>
                </div>
              );
            })}
          </dl>
        </div>
      ) : null}

      {/* --- live pool state -------------------------------------------- */}
      <div className={styles.block}>
        <span className="label">Pool</span>
        <dl className={styles.addresses}>
          <div className={styles.addressRow}>
            <dt className={styles.addressLabel}>Liquidity</dt>
            <dd className={styles.addressValue}>
              <Mono size="xs">{formatUnits(protocol.liquidity, 6, 0)}</Mono>
            </dd>
          </div>
          <div className={styles.addressRow}>
            <dt className={styles.addressLabel}>Total debt</dt>
            <dd className={styles.addressValue}>
              <Mono size="xs">{formatUnits(protocol.totalDebt, 6, 0)}</Mono>
            </dd>
          </div>
          <div className={styles.addressRow}>
            <dt className={styles.addressLabel}>Cap / wallet</dt>
            <dd className={styles.addressValue}>
              <Mono size="xs">{formatUnits(protocol.borrowCap, 6, 0)}</Mono>
            </dd>
          </div>
        </dl>
      </div>

      {/* --- signer service --------------------------------------------- */}
      <div className={styles.block}>
        <span className="label">Signer service</span>
        {health ? (
          <>
            <div className={styles.walletRow}>
              <Tag tone={health.signing_enabled ? "pos" : "neg"}>
                {health.signing_enabled ? "online" : "no key"}
              </Tag>
              <Mono size="xs" tone="faint">
                model v{health.model_version}
              </Mono>
            </div>
            <div className={styles.metaRow}>
              <Mono size="xs" tone="faint">
                AUC {health.model_auc ?? "—"}
              </Mono>
              <Mono size="xs" tone="faint">
                {health.feature_provider}
              </Mono>
            </div>
            {!health.trained_on_real_data ? (
              <span className={styles.bootstrapNote}>
                Model trained on synthetic bootstrap data. Scores demonstrate the mechanism,
                not real creditworthiness.
              </span>
            ) : null}
          </>
        ) : healthError ? (
          <span className={styles.errorNote}>{healthError}</span>
        ) : (
          <span className={styles.note}>checking…</span>
        )}
      </div>

      <nav className={styles.nav}>
        {SECTIONS.map((s) => (
          <a key={s.id} href={`#${s.id}`} className={styles.navLink}>
            {s.label}
          </a>
        ))}
      </nav>

      <div className={styles.footer}>
        <Mono size="xs" tone="faint">
          {deployment ? bpsToPercent(15000) : "—"} → {deployment ? bpsToPercent(11000) : "—"}
        </Mono>
        <span className={styles.footerNote}>collateral range, score 300 → 900</span>
      </div>
    </aside>
  );
}
