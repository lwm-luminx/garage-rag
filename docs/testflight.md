---
layout: default
title: Test Garage on TestFlight
description: How to join the TestFlight beta of Garage for the Mac App Store, install it, send feedback and go back to the website version.
testflight_page: true
---

{% assign testflight_open = false %}{% if site.testflight_url and site.testflight_url != "" %}{% assign testflight_open = true %}{% endif %}

<div class="hero">
  <h1>Test Garage on TestFlight</h1>
  <p>The App Store version of Garage 1.5 is in testing. TestFlight, Apple's app for beta software, installs it on your Mac and keeps it up to date while it's in testing.</p>
  {% if testflight_open %}
  <div class="hero-actions">
    <a id="testflight-join" href="{{ site.testflight_url }}" class="btn btn-primary btn-large" target="_blank" rel="noopener">Join the beta in TestFlight ↗</a>
  </div>
  <p class="download-meta">Apple Silicon · macOS 14 Sonoma or later · free while in testing</p>
  {% endif %}
</div>

{% unless testflight_open %}
<div class="callout callout-warn">
  <div class="callout-title">⏳ The beta isn't open yet</div>
  <p>The invitation link appears on this page when testing opens. Until then, the <a href="{{ '/#download' | relative_url }}">download on this site</a> is the way to run Garage.</p>
</div>
{% endunless %}

## Before you start

- A Mac with Apple Silicon (M1 or later) running macOS 14 Sonoma or later.
- An Apple Account signed in to the App Store.
- **Back up your Garage data if you already use Garage.** This is a test build, and it isn't finished. Quit Garage, then copy `~/Library/Application Support/GarageApp` somewhere safe (in Finder, choose **Go → Go to Folder…** and paste the path).

## Join and install

1. **Install TestFlight** from the Mac App Store: [TestFlight on the App Store ↗](https://apps.apple.com/app/testflight/id899247664){:target="_blank" rel="noopener"}.
2. **Open the invitation on your Mac.** {% if testflight_open %}Click [Join the beta in TestFlight]({{ site.testflight_url }}){:target="_blank" rel="noopener"}, then **View in TestFlight**.{% else %}The link will be on this page once testing opens.{% endif %}
3. **Accept, then Install.** TestFlight puts Garage in your Applications folder.
4. **Open Garage.** It appears in the menu bar and starts its private database. The first-run assistant picks your folders, an embedding model and the AI clients to connect. The [user guide]({{ '/support/guide.html' | relative_url }}) covers each step.
5. **Allow access when macOS asks.** To index Messages or Mail, give Garage Full Disk Access; the guide explains [how to grant it]({{ '/support/guide.html#macos-permissions' | relative_url }}).

## If you already use Garage from this site

macOS treats the App Store version and the version from this site as the same app, so installing from TestFlight replaces the copy in your Applications folder. Garage 1.5 from this site and from TestFlight keep their database in the same shared folder, so switching between them keeps your sources and index.

The TestFlight version gets its updates from TestFlight rather than checking this site, and it runs in the App Sandbox that the Mac App Store requires.

## Sending feedback

- **In TestFlight:** open TestFlight, select Garage and click **Send Beta Feedback**. You can attach a screenshot. If Garage crashes, TestFlight asks whether to send the crash report.
- **On GitHub:** [report a bug or ask a question]({{ '/support/contact.html' | relative_url }}) the same way as for the website version.

<div class="callout callout-info">
  <div class="callout-title">🛡️ What leaves your Mac</div>
  <p>Garage uploads nothing, in TestFlight as everywhere else. The feedback you choose to send and the crash reports you agree to share go through Apple's TestFlight app, under Apple's terms, and go to the developer. See the <a href="{{ '/support/privacy-policy.html' | relative_url }}">privacy policy</a> for everything Garage itself does.</p>
</div>

## Updates, expiry and going back

- New test builds show up in TestFlight. Turn on **Automatic Updates** for Garage there to get them without asking.
- Each test build stops opening 90 days after it was uploaded. A newer build replaces it before then, and your data stays where it is.
- To go back to the version from this site, quit Garage, move it from Applications to the Trash and install the [download from this site]({{ '/#download' | relative_url }}). To leave the beta, open Garage in TestFlight and click **Stop Testing**.
