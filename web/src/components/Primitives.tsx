"use client";

import type { ReactNode } from "react";

import styles from "./Primitives.module.css";

/** A number, address or hash. Always mono, always tabular. */
export function Mono({
  children,
  size = "sm",
  tone = "ink",
  title,
}: {
  children: ReactNode;
  size?: "xs" | "sm" | "md" | "lg" | "xl";
  tone?: "ink" | "muted" | "faint" | "pos" | "neg" | "accent";
  title?: string;
}) {
  return (
    <span className={`${styles.mono} ${styles[size]} ${styles[tone]}`} title={title}>
      {children}
    </span>
  );
}

export function Label({ children }: { children: ReactNode }) {
  return <span className="label">{children}</span>;
}

/** One headline figure: a label above, a large mono number below. */
export function Figure({
  label,
  value,
  unit,
  tone = "ink",
  hint,
}: {
  label: string;
  value: ReactNode;
  unit?: string;
  tone?: "ink" | "pos" | "neg" | "accent" | "faint";
  hint?: string;
}) {
  return (
    <div className={styles.figure}>
      <span className="label">{label}</span>
      <div className={styles.figureValue}>
        <Mono size="xl" tone={tone}>
          {value}
        </Mono>
        {unit ? (
          <span className={styles.figureUnit}>
            <Mono size="sm" tone="faint">
              {unit}
            </Mono>
          </span>
        ) : null}
      </div>
      {hint ? <span className={styles.figureHint}>{hint}</span> : null}
    </div>
  );
}

export function Panel({
  title,
  aside,
  children,
  id,
  emphasis = false,
}: {
  title: string;
  aside?: ReactNode;
  children: ReactNode;
  id?: string;
  emphasis?: boolean;
}) {
  return (
    <section id={id} className={`panel ${styles.panel} ${emphasis ? styles.panelEmphasis : ""}`}>
      <header className="panel__head">
        <h2 className="panel__title">{title}</h2>
        {aside ? <div className={styles.panelAside}>{aside}</div> : null}
      </header>
      <div className="panel__body">{children}</div>
    </section>
  );
}

export function Button({
  children,
  onClick,
  disabled,
  variant = "default",
  type = "button",
  title,
}: {
  children: ReactNode;
  onClick?: () => void;
  disabled?: boolean;
  variant?: "default" | "primary" | "danger" | "quiet";
  type?: "button" | "submit";
  title?: string;
}) {
  return (
    <button
      type={type}
      className={`${styles.button} ${styles[`button_${variant}`]}`}
      onClick={onClick}
      disabled={disabled}
      title={title}
    >
      {children}
    </button>
  );
}

/** Small status word. Used for verification verdicts and feature provenance. */
export function Tag({
  children,
  tone = "neutral",
}: {
  children: ReactNode;
  tone?: "neutral" | "pos" | "neg" | "accent" | "warn";
}) {
  return <span className={`${styles.tag} ${styles[`tag_${tone}`]}`}>{children}</span>;
}

/** A labelled row in a definition list. Keeps every panel on one grid. */
export function Row({
  label,
  children,
  title,
}: {
  label: string;
  children: ReactNode;
  title?: string;
}) {
  return (
    <div className={styles.row} title={title}>
      <span className={styles.rowLabel}>{label}</span>
      <span className={styles.rowValue}>{children}</span>
    </div>
  );
}
