---
layout: default
title: Garage Door
description: Garage Door lets Claude, ChatGPT and Garage on your phone reach your Garage from anywhere. Your computer dials out, so nothing on it listens; the door stores and logs none of what passes through, and holds no token it can read.
permalink: /door/
---

<div class="hero">
  <h1>Garage Door</h1>
  <p>The way in to your Garage from outside your network. Your computer opens one connection out to Garage Door, and the assistants you approve reach your Garage through it. No port forwarding, and nothing on your computer listens.</p>
  <div class="hero-actions">
    <a href="{{ '/pro/' | relative_url }}" class="btn btn-primary btn-large">Garage Pro and pricing</a>
    <a href="{{ site.door_url }}/sign-in" class="btn btn-secondary btn-large">Sign in to your account</a>
  </div>
  {% unless site.door_live %}<p class="download-meta"><span class="edition-badge">In testing</span> Garage Door arrives in a coming update of the Mac App Store version.</p>{% endunless %}
</div>

## How it works

<ol class="door-steps">
  <li>
    <h3>Turn on Garage Door in Garage</h3>
    <p>Garage on your computer signs in with Apple and creates your account there. It makes your keys on the computer, and your recovery keys stay with you. The website signs you in to an account; it never creates one.</p>
  </li>
  <li>
    <h3>Your computer dials out</h3>
    <p>Garage opens one outbound, encrypted connection to the door and keeps it open. Your router needs no changes, and there is nothing on your computer for a scanner to find.</p>
  </li>
  <li>
    <h3>Add an assistant, once</h3>
    <p>Your account has its own MCP address. Add it to Claude as a custom connector, or to ChatGPT as a connector, and approve it when Garage Door asks you to sign in. Each assistant appears in your account, where you can revoke it.</p>
  </li>
  <li>
    <h3>Every one of your computers answers</h3>
    <p>Garage Door sends each request to every computer on your account that's connected, and the answers come back side by side, each under its computer's name. An assistant can also ask one computer by name, or list which are online. Each computer answers under its own rules: the tools an assistant may use are set in Garage, read-only search by default.</p>
  </li>
</ol>

## What the door can and can't see

<div class="grid">
  <div class="card">
    <span class="card-icon">📭</span>
    <h3>It keeps nothing you search for</h3>
    <p>Garage Door stores, logs and caches no MCP content. For each request it records which door, which method, the status and the time. Never the question, never the answer.</p>
  </div>

  <div class="card">
    <span class="card-icon">🔑</span>
    <h3>It holds no secret it can read</h3>
    <p>Door keys and assistant tokens are kept only as one-way digests. Sign-ins to Dropbox, Google or Microsoft, and model keys you bring, are sealed to your own computers' keys; the door passes them along and can't open them.</p>
  </div>

  <div class="card">
    <span class="card-icon">🧭</span>
    <h3>Your computer decides</h3>
    <p>What an assistant may do is decided in Garage on each of your computers, never by the door. Your assistant's own sign-in to the door never reaches your computer, and only an allowlisted set of request headers crosses.</p>
  </div>
</div>

<div class="callout callout-info">
  <div class="callout-title">How private is it, honestly?</div>
  <p>For Claude and ChatGPT on the web, the connection is encrypted between the assistant and the door, and between the door and your computer, so the door's servers handle each request in memory on the way through. They keep none of it, but it is not end-to-end encryption. Garage Remote, the iPhone and iPad app, is built to be end to end: the door relays only ciphertext it cannot read. Either way, an assistant gets only the excerpts it searches for, never your whole library.</p>
</div>

## Your privacy level

One setting for your whole account decides what Garage Door may do. Each level keeps everything below it, and none of them uploads your library.

<ol class="privacy-levels">
  <li><strong>Entirely private.</strong> Everything stays on your computers. Door reaches none of them.</li>
  <li><strong>Entirely private, with remote access.</strong> Your assistants and Garage Remote reach your computers through Door's tunnel. Nothing is kept or read on the way. <em>Where every account starts.</em></li>
  <li><strong>Sharing between your own computers.</strong> Your computers share with each other through Door, which carries only sealed keys.</li>
  <li><strong>Semi private: your library, models you bring.</strong> Your library stays on your computers, which may send a question and its excerpts to a model provider you choose. Messages and mail still never leave them.</li>
  <li><strong>Augmented with Garage's servers.</strong> Garage's servers help your computers, and Door keeps the keys you give it in its vault.</li>
</ol>

You can make your account more private from anywhere, and it takes effect at once: Door closes your computers' connections when you go below remote access. Making it less private takes one of your own computers, so a stolen browser session can't open your account up.

## Questions

<details>
<summary>Do I need Garage Door to use Garage?</summary>
<p>No. Garage is free and works entirely on your computer, with assistants on the same computer connecting over MCP directly. Garage Door is for reaching it from somewhere else: an assistant on the web, or your phone.</p>
</details>

<details>
<summary>Which computers does it work on?</summary>
<p>Garage Door is built into the Mac App Store version of Garage first. The door itself works with any computer running Garage, and support for others follows the apps.</p>
</details>

<details>
<summary>Can I turn it off?</summary>
<p>Yes. Turn Garage Door off in Garage, or set your privacy level to entirely private from your account, and your computer's connection closes. Revoke an assistant from your account and it loses access at once.</p>
</details>

<details>
<summary>I have more than one computer. Do I add each one?</summary>
<p>No. Your assistants add your account's one address, and reach every computer you've turned Garage Door on for. A computer that's switched off or offline simply doesn't answer until it's back. Search results come back per computer for now, not merged into one list.</p>
</details>

<details>
<summary>What does it cost?</summary>
<p>One computer and two assistants are free. <a href="{{ '/pro/' | relative_url }}">Garage Pro</a> covers three computers and as many assistants as you like, for {{ site.pro_price_month }} a month or {{ site.pro_price_year }} a year.</p>
</details>
