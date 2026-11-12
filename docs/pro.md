---
layout: default
title: Garage Pro
description: Garage Pro adds Garage Door to Garage, so Claude, ChatGPT and your phone can search your Garage from anywhere while your files and index stay on your own computers. Free for one computer; $5 a month for three.
permalink: /pro/
---

<div class="hero pro-hero">
  <img src="{{ '/assets/logo.png' | relative_url }}" alt="" class="hero-logo" width="96" height="96">
  <div><span class="edition-lockup"><span>Garage</span><span class="edition-lockup-edition">Pro</span></span>{% unless site.door_live %} <span class="edition-badge">Coming soon</span>{% endunless %}</div>
  <h1>Your Garage, from anywhere.</h1>
  <p>Garage Pro adds Garage Door, so the assistants you choose can search your Garage from the web and from your phone. Your files and the index stay on your own computers, and nothing on them listens for a connection.</p>
  <div class="hero-actions">
    {% if site.door_live %}<a href="{{ site.app_store_url }}" class="btn btn-primary btn-large" target="_blank" rel="noopener">Get Garage on the Mac App Store</a>{% else %}<a href="{{ '/#download' | relative_url }}" class="btn btn-primary btn-large">Get Garage free today</a>{% endif %}
    <a href="{{ '/door/' | relative_url }}" class="btn btn-secondary btn-large">How Garage Door works</a>
  </div>
  {% if site.door_live %}<p class="download-meta">Turn on Garage Door in Garage's settings. Already set up? <a href="{{ site.door_url }}/sign-in">Sign in to your account</a>.</p>{% else %}<p class="download-meta">Garage Door is in testing and arrives in a coming update of the Mac App Store version. Garage itself stays free and open source.</p>{% endif %}
</div>

## What Pro adds

<div class="grid">
  <div class="card">
    <span class="card-icon">🚪</span>
    <h3>Claude and ChatGPT, on the web</h3>
    <p>Paste your door's address into Claude or ChatGPT and approve it once. They search your Garage through Garage Door, with no port forwarding and nothing for a scanner to find. You can revoke any assistant from your account.</p>
  </div>

  <div class="card">
    <span class="card-icon">📱</span>
    <h3>Garage on your iPhone and iPad <span class="pro-status">In development</span></h3>
    <p>Garage Remote searches, reads and asks your Garage from your phone. Answers come from the model on your computer; the phone holds no copy of your library. It ships with end-to-end encryption, so the door carries only ciphertext.</p>
  </div>

  <div class="card">
    <span class="card-icon">🔗</span>
    <h3>Your computers, together <span class="pro-status">Planned</span></h3>
    <p>Link the computers you run Garage on so any of them can answer from the others' libraries. Garage Door carries only sealed keys between them; your computers, not the door, decide which of them to trust.</p>
  </div>

  <div class="card">
    <span class="card-icon">☁️</span>
    <h3>Your cloud files, read where you are <span class="pro-status">In testing</span></h3>
    <p>Link Dropbox, and Google and Microsoft accounts, and your own computers read them straight from the provider. Garage Door handles the sign-in and hands the result, sealed, to your computers. It keeps no token it can read.</p>
  </div>

  <div class="card">
    <span class="card-icon">🗝️</span>
    <h3>Bring your own model, if you want one</h3>
    <p>Add a key for a model provider in Garage on your computer, and Garage seals it to each of your computers. Garage Door stores only ciphertext. It's off unless you choose it, and your messages and mail never go to that model.</p>
  </div>

  <div class="card">
    <span class="card-icon">🎚️</span>
    <h3>One privacy setting you control</h3>
    <p>Your account's privacy level decides what Garage Door may do, from "private node" up to "augmented"; assistants on the web need "private with public providers". Making it more private works from anywhere and takes effect at once; making it less private takes one of your own computers.</p>
  </div>
</div>

## Pricing

<div class="pricing">
  <section class="card pricing-plan">
    <h3>Garage</h3>
    <p class="pricing-price">Free</p>
    <p>The whole app, open source, on your computer.</p>
    <ul>
      <li>Index documents, code, notes, Messages and Mail</li>
      <li>Hybrid search and local models</li>
      <li>MCP for assistants on the same computer</li>
      <li>Garage Door for one computer and two assistants</li>
    </ul>
    <a href="{{ '/#download' | relative_url }}" class="btn btn-secondary">Download</a>
  </section>

  <section class="card card-accent pricing-plan pricing-plan-featured">
    <h3>Garage Pro</h3>
    <p class="pricing-price">{{ site.pro_price_month }}<small> a month</small></p>
    <p class="pricing-alt">or {{ site.pro_price_year }} a year</p>
    <ul>
      <li>Everything in Garage</li>
      <li>Garage Door for three computers</li>
      <li>As many assistants as you like</li>
      <li>Garage Remote, linked computers and cloud accounts as they arrive</li>
    </ul>
    {% if site.door_live %}<a href="{{ site.door_url }}/sign-in" class="btn btn-primary">Subscribe in your account</a>{% else %}<span class="edition-badge">Coming soon</span>{% endif %}
  </section>

  <section class="card pricing-plan edition-enterprise">
    <h3>Garage Enterprise</h3>
    <p class="pricing-price">Talk to us</p>
    <p>Garage for the whole organization, on infrastructure it runs.</p>
    <ul>
      <li>Your company's data remains in the company</li>
      <li>Agents search only what you permit</li>
      <li>Deploy through your device management</li>
    </ul>
    <a href="{{ site.enterprise_url | default: '/enterprise/' }}" class="btn btn-secondary">Learn about Enterprise</a>
  </section>
</div>

<p class="download-meta">Subscribe in Garage through the App Store, or on the web in your Garage Door account. Cancel whenever you like: an account that stops paying keeps the free plan.</p>

## What stays the same

Garage Pro changes where you can reach your Garage from, not where your Garage lives. Your files, the index, the database and the models stay on your computers. Garage Door carries requests to them and answers back; it stores, logs and caches none of what your assistants search for or find, and it never holds a password or token it can read. Garage itself is still free and open source, and nothing in Pro is needed to use it on your own computer.

<div class="callout callout-info">
  <div class="callout-title">Want the details?</div>
  <p><a href="{{ '/door/' | relative_url }}">How Garage Door works</a> covers the connection, what the door can and can't see, and the privacy levels. Questions? <a href="{{ '/support/contact.html' | relative_url }}">Get in touch</a>.</p>
</div>
