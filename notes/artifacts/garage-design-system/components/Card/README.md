# Card

A bordered `surface` panel (`radius-md`, `space-6` padding, `shadow-card`) for a feature, plan or doc link in a grid.

- Pass `title`, a short body as children (rendered in `ink-muted`), and optionally `badge` (a Badge, top left) and `footer` (a `violet-700` link line such as "Read more →").
- With `href` the whole card is a link: on hover it rises 2px, takes a `violet-500` border and `shadow-lift`.
- `selected` (`violet-050` fill, `violet-300` border) marks a picked option, as in the first-run assistant's template and model pickers.
- Lay cards out in a `minmax(300px, 1fr)` auto-fill grid with a `space-5` gap. No icons-as-emoji in the header.
