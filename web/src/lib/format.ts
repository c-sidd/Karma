/**
 * Number and address formatting.
 *
 * Everything returned here is meant to be rendered in the mono face with
 * tabular figures, so widths line up down a column.
 */

export function truncateAddress(address?: string | null, lead = 6, tail = 4): string {
  if (!address) return "—";
  if (address.length <= lead + tail + 2) return address;
  return `${address.slice(0, lead)}…${address.slice(-tail)}`;
}

export function truncateHex(hex?: string | null, lead = 10, tail = 8): string {
  if (!hex) return "—";
  if (hex.length <= lead + tail + 1) return hex;
  return `${hex.slice(0, lead)}…${hex.slice(-tail)}`;
}

/** Basis points as a percentage, always two decimals so columns align. */
export function bpsToPercent(bps?: bigint | number | null): string {
  if (bps === undefined || bps === null) return "—";
  const value = typeof bps === "bigint" ? Number(bps) : bps;
  return `${(value / 100).toFixed(2)}%`;
}

export function formatUnits(value: bigint | undefined, decimals: number, dp = 2): string {
  if (value === undefined) return "—";
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = abs % base;
  const fractionStr = fraction.toString().padStart(decimals, "0").slice(0, dp);
  const wholeStr = whole.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  const sign = negative ? "-" : "";
  return dp > 0 ? `${sign}${wholeStr}.${fractionStr}` : `${sign}${wholeStr}`;
}

export function formatCount(value: number, dp = 0): string {
  return value.toLocaleString("en-US", {
    minimumFractionDigits: dp,
    maximumFractionDigits: dp,
  });
}

/** Feature values span wallet age in days and borrow volume in dollars, so the
 *  precision has to follow the magnitude rather than a fixed rule. */
export function formatFeatureValue(value: number): string {
  if (Number.isInteger(value)) return formatCount(value);
  if (Math.abs(value) >= 1000) return formatCount(value, 0);
  if (Math.abs(value) >= 1) return formatCount(value, 3);
  return value.toFixed(6);
}

export function formatSeconds(seconds: number): string {
  if (seconds <= 0) return "expired";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  const hours = Math.floor(seconds / 3600);
  return `${hours}h ${Math.floor((seconds % 3600) / 60)}m`;
}

export function formatTimestamp(unix: number): string {
  return new Date(unix * 1000).toISOString().replace("T", " ").slice(0, 19) + "Z";
}
