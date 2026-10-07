import type * as React from 'react';
export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  /** primary: the one action a view is for. secondary (default): everything else. quiet: inline, low-emphasis. danger: destructive. */
  variant?: 'primary' | 'secondary' | 'quiet' | 'danger';
  size?: 'default' | 'large';
  /** Renders an <a> instead of a <button>. */
  href?: string;
  /** A 1.2em inline SVG placed before the label. */
  icon?: React.ReactNode;
}
export declare function Button(props: ButtonProps): React.ReactElement;
export interface BadgeProps {
  /** Plan / ingest state tones, or a corpus class (adds a dot). */
  tone?: 'neutral' | 'accent' | 'success' | 'warning' | 'danger' | 'corpus-document' | 'corpus-code' | 'corpus-communication';
  children?: React.ReactNode; className?: string;
}
export declare function Badge(props: BadgeProps): React.ReactElement;
export interface CardProps { title?: React.ReactNode; badge?: React.ReactNode; footer?: React.ReactNode; href?: string; selected?: boolean; children?: React.ReactNode; className?: string }
export declare function Card(props: CardProps): React.ReactElement;
export interface CalloutProps { tone?: 'info' | 'success' | 'warning' | 'danger'; title?: React.ReactNode; children?: React.ReactNode; className?: string }
export declare function Callout(props: CalloutProps): React.ReactElement;
export interface SearchFieldProps extends React.InputHTMLAttributes<HTMLInputElement> { /** Visually hidden label; default "Search". */ label?: string }
export declare function SearchField(props: SearchFieldProps): React.ReactElement;
export interface WordmarkProps {
  /** "garage" (default) or "enterprise", which adds the Enterprise lockup. */
  edition?: 'garage' | 'enterprise';
  /** Icon side in px; the name is set at 0.6×. Default 32. */
  size?: number;
  /** URL of the app icon (the Logos asset garage-icon-256.png). Omit for type only. */
  iconSrc?: string;
  className?: string;
}
export declare function Wordmark(props: WordmarkProps): React.ReactElement;
export interface TermProps {
  /** The term's name as the tooltip titles it ("Corpus"). */
  term: string;
  /** One or two plain sentences, at most about 30 words, saying what it is. */
  definition: React.ReactNode;
  /** The word as it reads in the sentence ("corpora"). */
  children: React.ReactNode;
  className?: string;
}
export declare function Term(props: TermProps): React.ReactElement;
declare global { interface Window { Garage: { Button: typeof Button; Badge: typeof Badge; Card: typeof Card; Callout: typeof Callout; SearchField: typeof SearchField; Wordmark: typeof Wordmark; Term: typeof Term } } }
