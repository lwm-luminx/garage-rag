---
layout: default
title: Glossary
description: The words Garage uses — corpus, chunk, embedding, hybrid search, MCP and more — each defined in a sentence or two.
---

# Glossary

The words Garage uses, each in a sentence or two. Across the site, a word with a dotted underline shows its definition when you point at it, tab to it or tap it.

<dl class="glossary">
{%- for entry in site.data.glossary %}
  <dt id="{{ entry[0] }}">{{ entry[1].name }}</dt>
  <dd>{{ entry[1].definition }}</dd>
{%- endfor %}
</dl>
