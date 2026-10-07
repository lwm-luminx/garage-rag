# Button

Use **primary** (`violet-500` fill, `on-brand` label) at most once per view, for the action the view exists for: "Download Garage", "Update Everything". Use **secondary** for everything else (`surface-raised` fill, `line` border). Use **quiet** for inline, low-emphasis actions in `violet-700`, and **danger** for destructive ones ("Reset Database"), always on a confirmation sheet.

- Labels are verbs in Title Case, matching desktop menu items: "Add Source", "Reset Database". Use an ellipsis (…) when the action opens a sheet or is in progress.
- Pass `href` to render a link that looks like a button. Pass `icon` for a 1.2em SVG before the label (a download arrow or a GitHub mark), never an emoji.
- `size="large"` is for the landing hero only.
- Focus: a 2px `focus` ring at a 2px offset, given by the stylesheet.
