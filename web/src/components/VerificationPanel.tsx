"use client";

import { useCallback, useMemo, useState } from "react";
import { usePublicClient, useWaitForTransactionReceipt, useWriteContract } from "wagmi";

import { scoreoracleAbi } from "@/generated/abis";
import { explorerTxUrl } from "@/lib/chains";
import { decodeRevert, isUserRejection } from "@/lib/errors";
import { formatSeconds, formatTimestamp, truncateAddress } from "@/lib/format";
import { useDeployment } from "@/lib/karma";
import type { AttestationFields, ScoreResponse } from "@/lib/signer";

import { Button, Mono, Tag } from "./Primitives";
import styles from "./VerificationPanel.module.css";

type ContractAttestation = {
  wallet: `0x${string}`;
  score: number;
  modelVersion: number;
  featureHash: `0x${string}`;
  expiry: bigint;
  nonce: bigint;
};

function toContractAttestation(a: AttestationFields): ContractAttestation {
  return {
    wallet: a.wallet,
    score: a.score,
    modelVersion: a.modelVersion,
    featureHash: a.featureHash,
    expiry: BigInt(a.expiry),
    nonce: BigInt(a.nonce),
  };
}

type Check = {
  /** The digest the contract computes for this attestation. */
  contractDigest: `0x${string}` | null;
  /** The address ecrecover returns inside the contract. */
  recovered: `0x${string}` | null;
  /** Whether the oracle has that address registered as a model signer. */
  registered: boolean | null;
  /** The error the submit path would revert with, if any. */
  revert: { errorName: string | null; message: string } | null;
  pending: boolean;
};

const EMPTY_CHECK: Check = {
  contractDigest: null,
  recovered: null,
  registered: null,
  revert: null,
  pending: false,
};

export function VerificationPanel({
  scored,
  onRequest,
  requesting,
  requestError,
  address,
}: {
  scored: ScoreResponse | null;
  onRequest: () => void;
  requesting: boolean;
  requestError: string | null;
  address?: `0x${string}`;
}) {
  const { deployment, chainId } = useDeployment();
  const publicClient = usePublicClient();
  const { writeContractAsync, isPending: writing } = useWriteContract();

  const [check, setCheck] = useState<Check>(EMPTY_CHECK);
  const [tamper, setTamper] = useState<Check | null>(null);
  const [txHash, setTxHash] = useState<`0x${string}` | null>(null);
  const [submitError, setSubmitError] = useState<string | null>(null);

  const receipt = useWaitForTransactionReceipt({
    hash: txHash ?? undefined,
    query: { enabled: Boolean(txHash) },
  });

  const oracle = deployment?.ScoreOracle;
  const attestation = scored?.attestation;

  /**
   * Ask the deployed contract, not the service, what it makes of this
   * attestation. Every value on screen below the fold comes from here.
   */
  const runCheck = useCallback(
    async (fields: AttestationFields, signature: `0x${string}`): Promise<Check> => {
      if (!publicClient || !oracle) {
        return { ...EMPTY_CHECK, revert: { errorName: null, message: "no chain connection" } };
      }
      const att = toContractAttestation(fields);
      const result: Check = { ...EMPTY_CHECK, pending: false };

      try {
        result.contractDigest = await publicClient.readContract({
          address: oracle,
          abi: scoreoracleAbi,
          functionName: "hashAttestation",
          args: [att],
        });
      } catch (error) {
        result.revert = decodeRevert(error);
        return result;
      }

      try {
        result.recovered = await publicClient.readContract({
          address: oracle,
          abi: scoreoracleAbi,
          functionName: "recoverAttestationSigner",
          args: [att, signature],
        });
        result.registered = await publicClient.readContract({
          address: oracle,
          abi: scoreoracleAbi,
          functionName: "isModelSigner",
          args: [result.recovered],
        });
      } catch (error) {
        result.revert = decodeRevert(error);
        return result;
      }

      // The submit path itself, executed against the deployed contract as an
      // eth_call. This is what surfaces BadSigner() before anyone spends gas.
      try {
        await publicClient.simulateContract({
          address: oracle,
          abi: scoreoracleAbi,
          functionName: "submitAttestation",
          args: [att, signature],
          account: address ?? att.wallet,
        });
      } catch (error) {
        result.revert = decodeRevert(error);
      }
      return result;
    },
    [publicClient, oracle, address]
  );

  const verify = useCallback(async () => {
    if (!attestation || !scored?.signature) return;
    setTamper(null);
    setCheck({ ...EMPTY_CHECK, pending: true });
    setCheck(await runCheck(attestation, scored.signature));
  }, [attestation, scored?.signature, runCheck]);

  /** Same signature, one field changed. The signature no longer covers it. */
  const submitTampered = useCallback(async () => {
    if (!attestation || !scored?.signature) return;
    setTamper({ ...EMPTY_CHECK, pending: true });
    const tampered: AttestationFields = { ...attestation, score: 900 };
    setTamper(await runCheck(tampered, scored.signature));
  }, [attestation, scored?.signature, runCheck]);

  const submit = useCallback(async () => {
    if (!attestation || !scored?.signature || !oracle) return;
    setSubmitError(null);
    try {
      const hash = await writeContractAsync({
        address: oracle,
        abi: scoreoracleAbi,
        functionName: "submitAttestation",
        args: [toContractAttestation(attestation), scored.signature],
      });
      setTxHash(hash);
    } catch (error) {
      if (!isUserRejection(error)) setSubmitError(decodeRevert(error).message);
    }
  }, [attestation, scored?.signature, oracle, writeContractAsync]);

  const digestsAgree =
    check.contractDigest !== null &&
    scored?.digest !== undefined &&
    check.contractDigest.toLowerCase() === scored.digest.toLowerCase();

  const verdict = useMemo(() => {
    if (!scored) return { tone: "neutral" as const, text: "no attestation" };
    if (check.pending) return { tone: "neutral" as const, text: "checking…" };
    if (check.revert)
      return { tone: "neg" as const, text: check.revert.errorName ?? "reverted" };
    if (check.registered === true && digestsAgree)
      return { tone: "accent" as const, text: "verified" };
    if (check.registered === false) return { tone: "neg" as const, text: "unregistered signer" };
    return { tone: "neutral" as const, text: "not checked" };
  }, [scored, check, digestsAgree]);

  const secondsLeft = attestation ? attestation.expiry - Math.floor(Date.now() / 1000) : 0;

  return (
    <section id="verification" className={`panel ${styles.panel}`}>
      <header className="panel__head">
        <div className={styles.headTitle}>
          <h2 className="panel__title">Verification</h2>
          <span className={styles.headSub}>
            What the contract does with the model&rsquo;s output before it prices anything
          </span>
        </div>
        <Tag tone={verdict.tone}>{verdict.text}</Tag>
      </header>

      <ol className={styles.steps}>
        {[
          { n: 1, label: "Request signed score", done: Boolean(scored?.signature) },
          { n: 2, label: "Rebuild digest on chain", done: digestsAgree },
          { n: 3, label: "Recover signer", done: check.recovered !== null },
          { n: 4, label: "Check against registry", done: check.registered === true },
        ].map((step) => (
          <li
            key={step.n}
            className={`${styles.step} ${step.done ? styles.stepDone : ""}`}
          >
            <Mono size="xs" tone={step.done ? "accent" : "faint"}>
              {String(step.n).padStart(2, "0")}
            </Mono>
            <span>{step.label}</span>
          </li>
        ))}
      </ol>

      {!scored ? (
        <EmptyState
          onRequest={onRequest}
          requesting={requesting}
          error={requestError}
          hasAddress={Boolean(address)}
        />
      ) : (
        <div className={styles.body}>
          <div className={styles.columns}>
            {/* ---------------------------------------- signed payload */}
            <div className={styles.column}>
              <span className="label">Signed payload</span>
              <table className={`tabular ${styles.fields}`}>
                <tbody>
                  <Field label="wallet" value={attestation?.wallet} full />
                  <Field label="score" value={attestation?.score} />
                  <Field label="modelVersion" value={attestation?.modelVersion} />
                  <Field label="featureHash" value={attestation?.featureHash} full />
                  <Field
                    label="expiry"
                    value={attestation ? formatTimestamp(attestation.expiry) : undefined}
                    note={secondsLeft > 0 ? `in ${formatSeconds(secondsLeft)}` : "expired"}
                  />
                  <Field label="nonce" value={attestation?.nonce} full />
                  <Field label="signature" value={scored.signature} full />
                </tbody>
              </table>
            </div>

            {/* ---------------------------------------- digest construction */}
            <div className={styles.column}>
              <span className="label">Digest construction</span>
              <div className={styles.construction}>
                <div className={styles.constructionRow}>
                  <span className={styles.constructionLabel}>EIP-712 domain</span>
                  <div className={styles.domain}>
                    <Mono size="xs" tone="muted">
                      name {scored.domain?.name} · version {scored.domain?.version}
                    </Mono>
                    <Mono size="xs" tone="muted">
                      chainId {scored.domain?.chainId}
                    </Mono>
                    <Mono size="xs" tone="muted" title={scored.domain?.verifyingContract}>
                      verifyingContract {truncateAddress(scored.domain?.verifyingContract, 8, 6)}
                    </Mono>
                  </div>
                  <span className={styles.constructionNote}>
                    Binding the chain id and this contract&rsquo;s own address is what stops the
                    same signature working on another chain or another deployment.
                  </span>
                </div>

                <Hash label="domainSeparator" value={scored.domain_separator} />
                <Hash label="structHash" value={scored.struct_hash} />

                <div className={styles.formula}>
                  <Mono size="xs" tone="faint">
                    digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)
                  </Mono>
                </div>

                <Hash label="digest (service)" value={scored.digest} />
                <Hash
                  label="digest (contract)"
                  value={check.contractDigest ?? undefined}
                  tone={digestsAgree ? "pos" : check.contractDigest ? "neg" : "ink"}
                  suffix={
                    check.contractDigest ? (
                      <Tag tone={digestsAgree ? "pos" : "neg"}>
                        {digestsAgree ? "identical" : "differs"}
                      </Tag>
                    ) : null
                  }
                />
              </div>
            </div>
          </div>

          {/* ---------------------------------------- recovery */}
          <div className={styles.recovery}>
            <div className={styles.recoveryGrid}>
              <RecoveryCell
                label="ecrecover returned"
                value={check.recovered}
                tone={check.registered === true ? "pos" : check.recovered ? "neg" : "ink"}
              />
              <RecoveryCell
                label="registered model signer"
                value={deployment?.modelSigner}
                tone="ink"
              />
              <div className={styles.recoveryCell}>
                <span className="label">isModelSigner(recovered)</span>
                <div className={styles.recoveryValue}>
                  {check.registered === null ? (
                    <Mono size="md" tone="faint">
                      —
                    </Mono>
                  ) : (
                    <Mono size="md" tone={check.registered ? "pos" : "neg"}>
                      {String(check.registered)}
                    </Mono>
                  )}
                </div>
              </div>
            </div>

            {check.revert ? (
              <div className={styles.revert}>
                <Tag tone="neg">reverted</Tag>
                <Mono size="sm" tone="neg">
                  {check.revert.errorName ? `${check.revert.errorName}()` : check.revert.message}
                </Mono>
                <span className={styles.revertNote}>
                  Raised by ScoreOracle when the recovered address is not a registered model
                  signer. No score is stored and no loan can be priced.
                </span>
              </div>
            ) : null}
          </div>

          {/* ---------------------------------------- controls */}
          <div className={styles.controls}>
            <Button onClick={verify} disabled={check.pending || !oracle}>
              {check.pending ? "Checking…" : "Verify against contract"}
            </Button>
            <Button
              variant="primary"
              onClick={submit}
              disabled={writing || !address || !oracle || check.registered !== true}
              title={
                check.registered !== true
                  ? "Verify against the contract first"
                  : "Submit the attestation on chain"
              }
            >
              {writing ? "Confirm in wallet…" : "Submit on chain"}
            </Button>
            <Button variant="danger" onClick={submitTampered} disabled={tamper?.pending}>
              {tamper?.pending ? "Submitting…" : "Submit tampered attestation"}
            </Button>
            <Button variant="quiet" onClick={onRequest} disabled={requesting}>
              {requesting ? "Requesting…" : "Re-request"}
            </Button>
          </div>

          {tamper && !tamper.pending ? <TamperResult check={tamper} /> : null}

          {txHash ? (
            <div className={styles.tx}>
              <Tag tone={receipt.data?.status === "success" ? "pos" : "neutral"}>
                {receipt.isLoading ? "pending" : (receipt.data?.status ?? "sent")}
              </Tag>
              <Mono size="xs" title={txHash}>
                {truncateAddress(txHash, 12, 10)}
              </Mono>
              {explorerTxUrl(chainId, txHash) ? (
                <a href={explorerTxUrl(chainId, txHash)!} target="_blank" rel="noreferrer">
                  <Mono size="xs">view on etherscan</Mono>
                </a>
              ) : (
                <Mono size="xs" tone="faint">
                  local chain — no explorer
                </Mono>
              )}
            </div>
          ) : null}

          {submitError ? (
            <div className={styles.revert}>
              <Tag tone="neg">submit failed</Tag>
              <Mono size="sm" tone="neg">
                {submitError}
              </Mono>
            </div>
          ) : null}
        </div>
      )}
    </section>
  );
}

/* ------------------------------------------------------------------ parts */

function Field({
  label,
  value,
  full,
  note,
}: {
  label: string;
  value?: string | number;
  full?: boolean;
  note?: string;
}) {
  return (
    <tr>
      <td className={styles.fieldLabel}>{label}</td>
      <td className={full ? styles.fieldValueFull : styles.fieldValue}>
        <span className="mono">{value ?? "—"}</span>
        {note ? <span className={styles.fieldNote}>{note}</span> : null}
      </td>
    </tr>
  );
}

function Hash({
  label,
  value,
  tone = "ink",
  suffix,
}: {
  label: string;
  value?: string;
  tone?: "ink" | "pos" | "neg";
  suffix?: React.ReactNode;
}) {
  return (
    <div className={styles.hashRow}>
      <div className={styles.hashHead}>
        <span className="label">{label}</span>
        {suffix}
      </div>
      <code className={`${styles.hashValue} ${tone === "pos" ? styles.hashPos : ""} ${
        tone === "neg" ? styles.hashNeg : ""
      }`}>
        {value ?? "—"}
      </code>
    </div>
  );
}

function RecoveryCell({
  label,
  value,
  tone,
}: {
  label: string;
  value?: string | null;
  tone: "ink" | "pos" | "neg";
}) {
  return (
    <div className={styles.recoveryCell}>
      <span className="label">{label}</span>
      <div className={styles.recoveryValue}>
        <Mono size="sm" tone={tone} title={value ?? undefined}>
          {value ? truncateAddress(value, 12, 10) : "—"}
        </Mono>
      </div>
    </div>
  );
}

function TamperResult({ check }: { check: Check }) {
  const rejected = Boolean(check.revert);
  return (
    <div className={rejected ? styles.tamperOk : styles.tamperBad}>
      <div className={styles.tamperHead}>
        <Tag tone={rejected ? "neg" : "warn"}>
          {rejected ? (check.revert?.errorName ?? "reverted") + "()" : "accepted"}
        </Tag>
        <span className={styles.tamperTitle}>
          {rejected
            ? "The contract rejected the tampered attestation"
            : "The tampered attestation was NOT rejected"}
        </span>
      </div>
      <p className={styles.tamperBody}>
        The score field was changed from the signed value to 900 and the original signature was
        reused. Changing any signed field changes the digest, so ecrecover returns a different
        address, and that address is not a registered model signer.
      </p>
      <div className={styles.tamperGrid}>
        <div>
          <span className="label">recovered from tampered payload</span>
          <div>
            <Mono size="sm" tone="neg" title={check.recovered ?? undefined}>
              {check.recovered ? truncateAddress(check.recovered, 12, 10) : "—"}
            </Mono>
          </div>
        </div>
        <div>
          <span className="label">isModelSigner</span>
          <div>
            <Mono size="sm" tone="neg">
              {check.registered === null ? "—" : String(check.registered)}
            </Mono>
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptyState({
  onRequest,
  requesting,
  error,
  hasAddress,
}: {
  onRequest: () => void;
  requesting: boolean;
  error: string | null;
  hasAddress: boolean;
}) {
  return (
    <div className={styles.empty}>
      <div className={styles.emptyCopy}>
        <p className={styles.emptyLead}>
          Nothing has been attested yet. Karma will score{" "}
          {hasAddress ? "the connected wallet" : "a wallet"} off chain, sign the result, and
          then hand the signature to the contract to check.
        </p>
        <p className={styles.emptyDetail}>
          Every field below will come from a contract call, not from the service. The service
          only makes a claim; the chain decides whether to believe it.
        </p>
      </div>
      <div className={styles.emptyActions}>
        <Button variant="primary" onClick={onRequest} disabled={requesting}>
          {requesting ? "Requesting…" : "Request signed score"}
        </Button>
        {error ? <span className={styles.emptyError}>{error}</span> : null}
      </div>
    </div>
  );
}
