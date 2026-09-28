---
layout: default
title: Privacy Policy
description: Privacy Policy and local-first data guarantees for Garage and GarageApp.
redirect_from:
  - /privacy-policy.html
---

# Privacy Policy

**Effective Date:** September 27, 2026  
**Application:** Garage & GarageApp  
**Developer:** Rick Mark-Penwell

---

## 1. Overview & Local-First Philosophy

Garage is designed from the ground up as a **local-first** personal knowledge indexing and retrieval application. We respect your privacy and have designed the application so that it does not collect, track, or sell user data, and does not transmit your content anywhere except to a model server you configure yourself (section 4). The few requests the application makes on its own, to fetch its model list, models you download, and updates, carry none of your data (section 5). This website, garagerag.app, uses Google Analytics to count visits; the application does not (section 6).

---

## 2. Data Collection

Garage does **not** collect personal information from users.

The application does not collect, store, transmit, or share:
- Names or identity data
- Email addresses or contact lists
- Account credentials or passwords
- Usage analytics or telemetry
- Device identifiers or hardware IDs
- Location data
- Documents, codebases, or file contents
- Personal images or scanned documents
- Search queries and retrieval results
- Application activity or runtime sessions

Garage contains **no advertising trackers, no analytics SDKs, and no background telemetry**.

---

## 3. Local Processing & Storage

All data indexed by Garage is processed and stored locally on your device in your private PostgreSQL database located in:  
`~/Library/Group Containers/DWVXMLB45Y.group.me.rickmark.garage-rag/Library/Application Support/GarageApp/pgdata`

Garage never sends your communications off your device, and sends other content only to a model server you have configured yourself (see section 4). Content you retrieve through a connected MCP client is subject to that client.

---

## 4. No Third-Party Services

Garage does not send your content to third-party services, and contains no client for any cloud AI service:

- **Text recognition (OCR)** in images uses Tesseract on your device. There is no cloud fallback.
- **Language models** for embeddings, fact extraction, and answers run in the application itself, or in a model server you run yourself (Ollama or LM Studio), on your device by default. If you configure an Ollama or LM Studio server on another computer, Garage sends the text it needs to process to that server and to no other address, and never sends private communications (Messages, Mail) to a server that is not on your device.

If you connect an MCP client such as Claude Desktop or Claude Code to Garage, the search results and document excerpts Garage returns to that client are then handled by that client and its provider under their own terms and privacy policies. Garage itself sends nothing to that client's provider; the client decides what it does with what it receives. Many clients send what they receive, together with your conversation, to their own cloud model provider, and that can include excerpts from Messages and Mail if you have indexed them. By default Garage's MCP server is reachable only from your own device; if you start it with `--allow-remote` to serve clients on other computers, it sends those results and excerpts to them over your network.

---

## 5. Network Requests the Application Makes

Apart from the model server you configure (section 4), Garage connects to the internet only for the following. None of these requests contains your documents, communications, search queries, or any identifier for you or your device.

- **Model list.** Each time it starts, GarageApp downloads the current list of recommended models (`https://garagerag.app/.data/models.json`) so its Models page and setup assistant can offer them. The request is an ordinary HTTPS download of a public file; it sends no data about you or your library.
- **Model downloads.** When you choose to download a model, GarageApp downloads that model file from Hugging Face (`huggingface.co` and the download servers it redirects to). It downloads nothing until you ask.
- **Update checks (website download only).** The version of GarageApp downloaded from this website can check `https://garagerag.app/appcast.xml` for new versions. It checks automatically only if you agree when it first asks. The App Store version gets updates from the App Store instead and makes no update checks of its own.

Like any server, garagerag.app (hosted on GitHub Pages) and Hugging Face receive the network information that every web request carries, such as your IP address and the app's user agent, and handle it under their own privacy policies. Garage does not receive or keep that information.

---

## 6. This Website

The website at garagerag.app, including these support pages, uses **Google Analytics** to count visits and see which pages people read. When you open a page, your browser loads Google's analytics script, which sets cookies and sends Google the page address, the referring page, your browser and device type, an approximate location derived from your IP address, and how you interact with the page. Google handles that information under the [Google Privacy Policy](https://policies.google.com/privacy). We use the reports only to understand how the site is used; we do not use them for advertising and do not combine them with anything else.

You can stop this collection with a content blocker that blocks Google Analytics, or with [Google's opt-out browser add-on](https://tools.google.com/dlpage/gaoptout).

This applies to the website only. GarageApp and the `garage` tools contain no analytics, and the website cannot see anything in your Garage library.

---

## 7. Security & Access Control

- **Keychain Security**: Database superuser passwords and optional API tokens (e.g., LM Studio API keys) are stored securely in the native **macOS Keychain**.
- **Loopback by default**: By default the embedded HTTP MCP server binds only to `127.0.0.1` and refuses remote clients, and it checks the Host and Origin headers so web pages cannot reach your corpus. Serving other computers takes an explicit opt-in for power users, `--allow-remote`; with it, and with no `--allow-host`, the Host check is off.
- **macOS Sandboxing & TCC**: Access to protected directories (Documents, Downloads, Desktop, Messages, Mail) requires explicit macOS user authorization under System Settings.

---

## 8. Children's Privacy

Garage does not knowingly collect information from children or any other users. Because the application does not collect personal data, it does not knowingly collect personal data from children under 13 or the equivalent minimum age in other jurisdictions.

---

## 9. Changes to This Policy

This Privacy Policy may be updated from time to time. Any material updates will be published to this website and included with subsequent application releases.

---

## 10. Contact

If you have questions about this Privacy Policy or our local-first security architecture, please reach out:

- **GitHub Issues**: [https://github.com/rickmark/garage-rag/issues](https://github.com/rickmark/garage-rag/issues)
- **Email**: [privacy@rickmark.com](mailto:privacy@rickmark.com)
