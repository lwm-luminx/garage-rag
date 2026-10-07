# Wordmark

The Garage lockup: the app icon, then "Garage" set in the system sans at 600. With `edition="enterprise"` it adds a hairline divider and "Enterprise" in `violet-700`. This is the only way to write the Enterprise name.

- Pass `iconSrc`: the Logos asset `garage-icon-256.png` (or the 1024 version for large sizes) for Garage, and `garage-enterprise-icon.svg` for Enterprise. Without it the lockup is type only, for places where the icon already shows nearby.
- `size` is the icon side in px (default 32, as in the site header). The name is set at 0.6× that.
- Pair `edition="enterprise"` with an Enterprise theme (`data-theme="enterprise-light"` or `"enterprise-dark"`) on the same page. Never put the Enterprise lockup on Garage's own violet themes, or the Garage lockup on Enterprise themes.
- Never recolour, outline or re-draw the icon.
