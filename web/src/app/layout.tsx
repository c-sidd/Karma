import type { Metadata } from "next";
import { IBM_Plex_Mono, IBM_Plex_Sans } from "next/font/google";

import { Providers } from "./providers";
import "./globals.css";

/**
 * Type: IBM Plex Sans and IBM Plex Mono.
 *
 * Plex was drawn for technical documentation and instrument readouts, and it
 * shows: the sans is a slightly narrow grotesque with squared terminals that
 * reads as engineered rather than friendly, and the mono carries true tabular
 * figures with a slashed zero, which is what keeps a column of hashes and
 * balances aligned. The two are metrically related, so a mono number sits on
 * the same rhythm as the sans label beside it.
 *
 * Weights are deliberate: 400 for body, 500 for labels, 600 for headings only.
 */
const sans = IBM_Plex_Sans({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-sans",
  display: "swap",
});

const mono = IBM_Plex_Mono({
  subsets: ["latin"],
  weight: ["400", "500", "600"],
  variable: "--font-mono",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Karma — credit-scored lending",
  description:
    "A lending protocol that prices collateral from a signed credit score, and checks the signature on chain before it prices anything.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${sans.variable} ${mono.variable}`}>
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
