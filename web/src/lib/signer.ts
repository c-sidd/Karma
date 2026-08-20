/**
 * Client for the Karma signer service.
 *
 * The service is the only thing that can turn a wallet address into a signed
 * score. Everything it returns is treated as a claim until the contract has
 * recovered the signature, which is exactly what the verification panel shows.
 */

export type FeatureSource = "synthetic" | "chain";

export type ScoredFeature = {
  name: string;
  value: number;
  source: FeatureSource;
  contribution: number;
  baseline: number;
};

export type AttestationFields = {
  wallet: `0x${string}`;
  score: number;
  modelVersion: number;
  featureHash: `0x${string}`;
  expiry: number;
  nonce: string | number;
};

export type FeatureProvenance = {
  provider: string;
  fully_real: boolean;
  real_features: string[];
  synthetic_features: string[];
  warning: string | null;
};

export type DataSource = {
  kind?: string;
  is_real_data?: boolean;
  label?: string;
  query_url?: string | null;
  n_rows?: number;
};

export type ScoreResponse = {
  wallet: `0x${string}`;
  score: number;
  probability_of_default: number;
  model_version: number;
  collateral_ratio_bps: number;
  collateral_ratio_percent: number;
  features: ScoredFeature[];
  feature_hash: `0x${string}`;
  feature_provenance: FeatureProvenance;
  data_source: DataSource;
  chain_id: number;
  score_oracle: `0x${string}`;
  issued_at: number;
  attestation?: AttestationFields;
  domain?: { name: string; version: string; chainId: number; verifyingContract: `0x${string}` };
  digest?: `0x${string}`;
  domain_separator?: `0x${string}`;
  struct_hash?: `0x${string}`;
  signature?: `0x${string}`;
  signer?: `0x${string}`;
  calldata?: `0x${string}`;
  to?: `0x${string}`;
  signed: boolean;
  warning?: string;
};

export type HealthResponse = {
  status: string;
  model_version: number;
  model_auc: number | null;
  trained_on_real_data: boolean;
  data_label: string | null;
  feature_provider: string;
  chain_id: number;
  score_oracle_address: string;
  signing_enabled: boolean;
  attestation_ttl_seconds: number;
};

export type ModelReport = {
  model_version: number;
  algorithm: string;
  metrics: { auc_test: number; auc_train: number; ks_test: number; brier_test: number };
  data_source: DataSource;
  dataset: { n_total: number; n_train: number; n_test: number; base_default_rate: number };
  score_bands: {
    band: string;
    n: number;
    default_rate: number | null;
    collateral_ratio_bps: number;
  }[];
  capital_efficiency: { collateral_freed_pct: number; borrowing_power_lift_pct: number };
  feature_importance: { name: string; importance: number }[];
};

export const SIGNER_URL = process.env.NEXT_PUBLIC_SIGNER_URL ?? "http://localhost:8000";

export class SignerUnreachableError extends Error {
  constructor(url: string, cause?: unknown) {
    super(
      `Cannot reach the signer service at ${url}. Start it with \`make signer\`, ` +
        `or set NEXT_PUBLIC_SIGNER_URL.`
    );
    this.name = "SignerUnreachableError";
    this.cause = cause;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${SIGNER_URL}${path}`, {
      ...init,
      headers: { "content-type": "application/json", ...(init?.headers ?? {}) },
    });
  } catch (cause) {
    throw new SignerUnreachableError(SIGNER_URL, cause);
  }

  if (!response.ok) {
    let detail = `${response.status} ${response.statusText}`;
    try {
      const body = (await response.json()) as { detail?: string };
      if (body.detail) detail = body.detail;
    } catch {
      /* response had no JSON body; the status line is all we have */
    }
    throw new Error(detail);
  }
  return (await response.json()) as T;
}

export const signerApi = {
  health: () => request<HealthResponse>("/health"),
  modelReport: () => request<ModelReport>("/model-report"),
  score: (address: string) =>
    request<ScoreResponse>("/score", { method: "POST", body: JSON.stringify({ address }) }),
  attestation: (address: string) => request<ScoreResponse>(`/attestation/${address}`),
};
