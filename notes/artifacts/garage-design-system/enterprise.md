# Garage Enterprise

Garage Enterprise is the second edition. It keeps Garage's structure (the same token names, type scale, spacing, radii and components) and changes only the **brand layer**. Its violet is deeper and cooler (a plum-indigo, `violet-500` = #4b2c9f in light) and sits on slate neutrals, which read as managed and institutional next to Garage's warmer lavender.

## Using it in a product

1. Set `data-theme="enterprise-light"` or `"enterprise-dark"` on `<html>` (or on the subtree that is Enterprise). Every component restyles; there are no separate Enterprise components.
2. Use the Enterprise lockup: `Wordmark` with `edition="enterprise"`. Write the name "Garage Enterprise" in full the first time it appears, then "Enterprise" is fine in context ("Enterprise policies").
3. Keep the voice of the base system, with a few shifts: speak to the organisation as well as the person ("your team's corpus"); name the admin controls exactly; make privacy statements auditable ("Communications stay on the device; administrators cannot read them").

## The brand layer (what Enterprise overrides)

Only these tokens have Enterprise values; every other token inherits Garage Light:

| Layer | Tokens |
| --- | --- |
| Brand ramp | `violet-050`, `violet-100`, `violet-300`, `violet-400`, `violet-500`, `violet-700`, `violet-900`, `on-brand` |
| Neutrals | `surface`, `surface-raised`, `surface-sunken`, `ink`, `ink-muted`, `ink-faint`, `line`, `line-subtle`, `line-strong` |
| Corpus | `corpus-document` (slightly deeper blue on slate) |

Status colours, the other corpus colours, `focus` (an alias of `violet-500`), type, spacing, radii and shadows are shared. Every overridden text pair still meets 4.5:1.

## Splitting it into its own design system

When Enterprise needs its own home (separate owners, its own logo or extra components), make a second system from this one instead of starting fresh:

1. Create a new Design System titled **Garage Enterprise**.
2. Copy `tokens.json` and change the `themes` order so `enterprise-light` comes first and `enterprise-dark` second. Then either delete Garage's `light` and `dark` values or keep them as reference themes. The first theme is the one every missing value falls back to, so it must be the Enterprise one.
3. Copy `components/` unchanged and set the Wordmark previews to `edition="enterprise"` with the Enterprise icon.
4. Copy this README, and make this section its introduction.
5. Give it a new cover from the Enterprise ramp: `violet-500`, `violet-900` and `violet-100` on the slate `surface`.
6. Keep the token names unchanged. Shared names are what let a product move between editions by switching `data-theme`.

Enterprise has its own icon, `garage-enterprise-icon.svg` (with a 512px PNG) in Logos. It redraws the Garage glyph in the Enterprise language: a `violet-500` plum tile, the plus in white, the triangles and squared quarter-disc leaves in `violet-100`, and an inset `violet-300` hairline, the fence that stands for a managed boundary. Pass it to `Wordmark` as `iconSrc` with `edition="enterprise"`. Carry it into the split-out system's Logos group.
