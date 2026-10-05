---
layout: default
title: Engineering Plans
description: Design notes and engineering plans for Garage, the local RAG app and MCP server. What is proposed, what is in progress and what has landed, with the measurements and decisions behind each.
---

<div class="hero">
  <h1>Engineering plans</h1>
  <p>How Garage is going to change, written down before the code. Each plan records the problem, the measurements or research behind it, the design, the milestones and the decisions still open, and keeps a status line as the work lands. They live in <a href="https://github.com/rickmark/garage-rag/tree/main/docs/plans" target="_blank" rel="noopener"><code>docs/plans/</code></a> in the repository; the way to discuss one is <a href="https://github.com/rickmark/garage-rag/issues" target="_blank" rel="noopener">an issue</a> or a pull request that edits it.</p>
</div>

{% assign plans = site.pages | where_exp: "p", "p.url contains '/plans/'" | where_exp: "p", "p.name != 'index.md'" | sort: "date" | reverse %}
<div class="grid plans-grid">
{% for plan in plans %}
  <div class="card">
    <span class="plan-status plan-status-{{ plan.status_kind | default: 'proposed' }}">{{ plan.status | default: "Proposed" }}</span>
    <h3><a href="{{ plan.url | relative_url }}">{{ plan.title }}</a></h3>
    <p>{{ plan.description }}</p>
    <a href="{{ plan.url | relative_url }}" class="card-link">Read the plan →</a>
  </div>
{% endfor %}
</div>

## How a plan is written

A plan is a Markdown file in `docs/plans/` with front matter the index above reads:

```yaml
---
layout: default
title: Short name of the plan
description: One sentence on what it changes and why.
date: 2026-10-04          # when it was written; the index sorts on it
status: Proposed          # the current state, in a few words
status_kind: proposed     # proposed | active | landed | deferred | reference
---
```

The body opens with a status note when the state has moved on from the text below it, as the [v1.5 plan]({{ '/plans/v1.5.html' | relative_url }}) does. Measurements come with the command that produced them, so they can be re-run. Line numbers go stale; file paths and function names last longer.
