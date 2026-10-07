# Term

A word in running text that shows its definition on hover, keyboard focus or tap: the shared way Garage explains its vocabulary (corpus, chunk, embedding, hybrid search) on the website, in docs and in the app.

**The trigger** is the word itself, in the surrounding text's colour, with a 1.5px dotted underline in `violet-500` at a 3px offset and a help cursor. Hovered or open, it turns `violet-700` and the underline goes solid. It is a real `<button>`, so it takes focus, and focus shows the 2px `focus` ring.

**The tip** is a small raised card above the word (below it if there is no room): a `surface` card with a `line` border, `radius-md` corners, `shadow-lift` and a caret pointing at the word. The term's name comes first at 600 in `ink`, then the definition in the `term` style (`ink-muted`). It is at most 300px wide and stays 16px inside the viewport.

**Behaviour**: it opens on hover after 120ms, so passing the pointer over a paragraph doesn't flash tips; at once on focus or tap. Escape, a tap elsewhere or moving away closes it. It fades in over 120ms with a 4px rise, and reduced motion turns the motion off. The tip is `role="tooltip"`, linked to the button by `aria-describedby`.

**Writing definitions**:
- One or two plain sentences, at most about 30 words. Say what the thing is, not "A term for …": "A passage of a document."
- Use Garage's own words, and say where it matters for privacy: "Communications never leave your computer."
- Define a word at its first use on a page, not at every use, and never inside a heading, button or link.
- Keep definitions in one glossary (garagerag.app uses `_data/glossary.yml`), so the same word means the same thing everywhere.

Props: `term` (the name the tip titles), `definition`, and `children` (the word as the sentence reads it, such as "corpora").
