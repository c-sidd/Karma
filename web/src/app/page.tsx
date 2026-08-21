"use client";

import { useCallback, useEffect, useState } from "react";
import { useAccount } from "wagmi";

import { Masthead } from "@/components/Masthead";
import { ModelPanel } from "@/components/ModelPanel";
import { PositionPanel } from "@/components/PositionPanel";
import { Rail } from "@/components/Rail";
import { ScoreBreakdown } from "@/components/ScoreBreakdown";
import { VerificationPanel } from "@/components/VerificationPanel";
import { signerApi, type ModelReport, type ScoreResponse } from "@/lib/signer";

import styles from "./page.module.css";

export default function Page() {
  const { address } = useAccount();

  const [scored, setScored] = useState<ScoreResponse | null>(null);
  const [requesting, setRequesting] = useState(false);
  const [requestError, setRequestError] = useState<string | null>(null);

  const [report, setReport] = useState<ModelReport | null>(null);
  const [reportError, setReportError] = useState<string | null>(null);
  const [reportLoading, setReportLoading] = useState(true);

  // A score belongs to one wallet. Switching accounts must not leave the
  // previous wallet's attestation on screen.
  useEffect(() => {
    setScored(null);
    setRequestError(null);
  }, [address]);

  useEffect(() => {
    let cancelled = false;
    signerApi
      .modelReport()
      .then((r) => !cancelled && setReport(r))
      .catch((e: Error) => !cancelled && setReportError(e.message))
      .finally(() => !cancelled && setReportLoading(false));
    return () => {
      cancelled = true;
    };
  }, []);

  const requestScore = useCallback(async () => {
    if (!address) {
      setRequestError("Connect a wallet first. The attestation is bound to a specific address.");
      return;
    }
    setRequesting(true);
    setRequestError(null);
    try {
      setScored(await signerApi.score(address));
    } catch (error) {
      setRequestError(error instanceof Error ? error.message : String(error));
    } finally {
      setRequesting(false);
    }
  }, [address]);

  return (
    <div className={styles.shell}>
      <Rail />
      <main className={styles.work}>
        <Masthead address={address} scored={scored} />

        <div className={styles.stack}>
          <VerificationPanel
            scored={scored}
            onRequest={requestScore}
            requesting={requesting}
            requestError={requestError}
            address={address}
          />
          <ScoreBreakdown scored={scored} />
          <PositionPanel address={address} />
          <ModelPanel report={report} error={reportError} loading={reportLoading} />
        </div>

        <footer className={styles.footer}>
          <span>
            Sepolia testnet. Test tokens are mintable and worthless. The price oracle publishes
            owner-set prices because Sepolia has no liquid markets to read.
          </span>
        </footer>
      </main>
    </div>
  );
}
