Garage is a local-first personal RAG app for macOS, Windows and Linux: it indexes your documents, code and mail on your own computer and serves them to your AI assistants over MCP. The brand is calm, technical and private, a well-organised workshop rather than a cloud service. It is built around one colour: **Garage violet**, the body of the app icon.

This system covers two editions that share every token name:

- **Garage**: the themes `light` and `dark`. A warm violet brand on violet-tinted neutrals.
- **Garage Enterprise**: the themes `enterprise-light` and `enterprise-dark`. A deeper plum-indigo brand on cool slate neutrals, for team and managed deployments. See the *Garage Enterprise* section for how to apply it or split it into its own system.

## Content fundamentals

- **Voice**: plain, exact and reassuring about privacy. Say what happens and where the data stays: "Communications never leave the machine." "Deletes the index. Your source files are not touched." No hype, no exclamation marks.
- **Person**: speak to the user as *you* and refer to the product as *Garage* (never "we"). "Garage indexes your files on your computer."
- **Cross-platform**: Garage is not a Mac product. Say *your computer*, never *your Mac*, and call the app *Garage*, never *Garage for Mac*. Name an operating system (*macOS*, *Windows*, *Linux*) only where the text is about that platform: a download, a system requirement, a build step. Proper names such as *Mac App Store* stay.
- **Casing**: Title Case for buttons, menu items and page names, as in macOS ("Update Everything", "Reset Database", "MCP Server"). Sentence case for headings in docs and for body text.
- **Terms**: use the codebase's words: *source*, *corpus*, *document*, *chunk*, *fact*, *embedding model*, *backfill*. Corpus classes are *document*, *code* and *communication*. Trust tiers are *authored*, *reference* and *received*. Write commands in `code` exactly as typed: `garage enrich-facts --stale-only`.
- **No emoji** in UI or docs. Status is a word plus a colour (Badge), never a colour alone.

## Colour

- `violet-500` is the brand. Use it for the primary button, the active nav item, the focus ring and hovered card borders. Spend it sparingly: one primary action per view.
- Set links and accent text in `violet-700` on `surface` and `surface-raised` (above 7:1 in light). In the dark themes the same token turns light lavender.
- Use `violet-100` and `violet-050` for quiet emphasis (info callouts, accent badges, selected cards), with `violet-900` or `ink` text on them.
- `violet-400` is the icon's highlight. Use it only for decoration (cover, charts); it is not a text colour on light grounds.
- Neutrals: `surface` is the page, `surface-raised` the chrome (header, footer, table stripes, secondary buttons) and `surface-sunken` pressed states and wells. Text in `ink`, secondary text in `ink-muted`, meta lines and placeholders in `ink-faint`. Borders in `line`, hairlines in `line-subtle`, control borders that need 3:1 in `line-strong`.
- Put text on `violet-500` only in `on-brand` (white in light themes, near-black in dark themes, where the violet is lighter).
- Status colours `success`, `warning` and `danger` each have a `-soft` ground. Always pair them with a word or icon.
- Corpus classes keep the app's colour code: `corpus-document` blue, `corpus-code` violet, `corpus-communication` green.
- Every text token meets 4.5:1 on the grounds its usage note names, in all four themes. Large text, icons and control borders meet 3:1.
- Avoid blue-to-purple gradients and glows. The brand is a flat, solid violet, as in the icon.

## Typography

- The brand face is **IBM Plex Sans** (`font-sans`), with **IBM Plex Mono** (`font-mono`) for code. Both are open source under the SIL OFL, well hinted for Windows ClearType, and have sister families for other scripts (Plex Sans Arabic, JP, KR and more). The same face on macOS, Windows, Linux and the web keeps the brand consistent across platforms. Self-host the files in `fonts/` (Latin; add the Latin Extended or other-script subsets as the product needs them) and never load them from a third-party CDN.
- The fallbacks are each platform's system UI face. Native controls that the OS draws (menus, alerts, the macOS menu bar) keep the system face; Garage's own surfaces use Plex.
- Scale: `display` (landing hero only), `title-1` (page title, with a `line-subtle` rule under it), `title-2`, `title-3`, `body` (16px, line-height 1.6; 1.7 in long prose), `body-small` (blurbs, captions), `label` (buttons, nav), `badge` (uppercase pills), `term` (tooltip body) and `code`.
- Titles at 700 and headings at 600 have slightly negative tracking (-0.02em on display sizes). Body text is 400. Use `eyebrow` (uppercase, +0.08em, `violet-700`) for a kicker above a title.

## Space, shape and depth

- Spacing runs on a 4px base: `space-1` (4) to `space-10` (40). Pad cards with `space-6`, callouts and code blocks with `space-4`, and separate cards in a grid with `space-5`. The content column is 1040px wide with `space-6` side padding, or a `space-4` gutter on phones.
- Radii: `radius-xs` for inline code, `radius-sm` for buttons, `radius-md` for cards, inputs and code blocks, `radius-lg` for hero and feature panels, `radius-pill` for badges, `radius-icon` for the app icon at 80px.
- Depth is low. Cards rest on a 1px `line` border plus `shadow-card`. On hover a linked card rises 2px and takes `shadow-lift` and a `violet-500` border. Window screenshots get their macOS shadow from CSS, never baked into the image.
- Motion: 150ms ease on colour, border, shadow and a 2px lift. Nothing bounces or loops.
- Focus: every interactive control shows a 2px solid `focus` ring (`violet-500`) at a 2px offset. Text inputs also show a `violet-100` halo.

## Iconography and imagery

- The app icon (Logos group) is Garage's mark: a lavender plus-and-leaf glyph on a violet tile. Use it as is, at 16px or larger, with `radius-icon` rounding when it is cropped square. Use the Wordmark component for the lockup.
- Garage | Enterprise has its own icon (`garage-enterprise-icon.svg`): the same glyph geometry on a plum tile, with the leaves squared into quarter-discs and an inset hairline "fence" for the managed boundary. Use it only with the Enterprise themes.
- UI icons are SF Symbols in the macOS app and Fluent icons in the Windows app. On the web use simple 1.5px-stroke inline SVGs, sized 1.2em next to a label and coloured with `currentColor`. No emoji, no illustrated mascots.
- Show the real app (window screenshots in light and dark) rather than stock imagery. Diagrams come in light and dark SVG pairs.

## Components

- `Button`: primary, secondary, quiet or danger, in two sizes.
- `Badge`: status and corpus-class pills.
- `Card`: grid panels for features, plans and docs.
- `Callout`: info, success, warning and danger notes.
- `SearchField`: the corpus search box.
- `Wordmark`: the Garage and Garage Enterprise lockups.
- `Term`: a word with its definition on hover, focus or tap, for the product's vocabulary (corpus, chunk, embedding).

They read only CSS custom properties, so switching `data-theme` on `<html>` or on any container restyles them for either edition.
