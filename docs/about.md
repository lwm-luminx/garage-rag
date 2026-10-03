---
layout: default
title: About the creator
description: Rick Mark-Penwell, the creator of Garage, is a security and AI engineer, formerly of Meta, Coinbase,
  Dropbox and Microsoft, known for his research into Apple's T2 chip.
---

<section class="profile">
  <img class="profile-photo" src="https://avatars.githubusercontent.com/u/125403?s=320&v=4" width="160" height="160" alt="Rick Mark-Penwell">
  <div class="profile-body">
    <p class="profile-eyebrow">The creator of Garage</p>
    <h1>Rick Mark-Penwell</h1>
    <p class="profile-role">Security, privacy and AI engineer · Apple hardware security researcher</p>
    <p class="profile-badge"><span class="profile-badge-dot" aria-hidden="true"></span>Available for AI security, privacy engineering and security research roles</p>
    <div class="profile-actions">
      <a href="https://linkedin.com/in/penwellr" class="btn btn-primary" target="_blank" rel="noopener">Get in touch on LinkedIn ↗</a>
      <a href="https://github.com/rickmark" class="btn btn-secondary" target="_blank" rel="noopener">GitHub ↗</a>
      <a href="https://www.patreon.com/rickmark" class="btn btn-secondary" target="_blank" rel="noopener">Patreon ↗</a>
    </div>
  </div>
</section>

Rick is a security, privacy, and AI engineer and a hardware security researcher who has worked on Apple platforms
since 2007, and has spent more than fifteen years in security engineering, most recently using AI where it genuinely
helps.

<p class="profile-note">His Apple developer account dates from 2007 and still carries his prior name, Richard Penwell, so that's the name on Garage's Developer ID signature. Rick Mark and Richard Penwell are the same person, and Garage's copyright uses the hyphenated name to make that clear.</p>

<div class="stats">
  <div class="stat"><strong>15+</strong><span>years in security engineering</span></div>
  <div class="stat"><strong>2007</strong><span>building on Apple platforms</span></div>
  <div class="stat"><strong>1,400+</strong><span>GitHub stars on apple-knowledge</span></div>
  <div class="stat"><strong>25+</strong><span>outside projects with merged PRs</span></div>
</div>

## Career

<ol class="timeline">
  <li>
    <h3>Meta <span>Privacy Engineer</span></h3>
    <p>He was key to PrivacyBrain, an LLM derived from Llama that evaluated privacy incidents, reviews, and FTC commitments across hundreds of millions of records, and Project Terminus, which linked incidents to their root causes and replaced months of manual investigation with consistent automation. He also wrote an LLVM-bitcode scanner (PSAPI) for sensitive iOS and macOS APIs and contributed to the design of Llama 4.</p>
  </li>
  <li>
    <h3>Coinbase <span>Security Architect</span></h3>
  </li>
  <li>
    <h3>Dropbox <span>Senior Security Engineer</span></h3>
    <p>He worked on corporate authentication, key management and Windows security in the datacenters, and open-sourced efivalidate for checking Mac firmware.</p>
  </li>
  <li>
    <h3>Uber Advanced Technologies Group <span>Senior Security Engineer</span></h3>
  </li>
  <li>
    <h3>Jet.com <span>Senior Software Security Engineer</span></h3>
    <p>He was the company's first security engineer, securing what was then the largest e-commerce site on Azure.</p>
  </li>
  <li>
    <h3>Bloomberg <span>Senior Web Application Developer</span></h3>
    <p>On Bloomberg's legal research platform.</p>
  </li>
  <li>
    <h3>Microsoft <span>Software Engineer, then Azure Security SDE II</span></h3>
    <p>He did threat modeling and penetration testing for Azure, automated security health reporting across more than 150 teams, and worked on the Windows Data Classification Toolkit. He holds a patent on <a href="https://patents.google.com/patent/US20160006760A1" target="_blank" rel="noopener">detecting and preventing phishing attacks</a>.</p>
  </li>
</ol>

He also founded **Hot Mess**/**AudienceKit**, products that apply social science to in-person community (more below).

## Apple security research

<div class="feature-panel">
  <div class="feature-panel-main">
    <p>He is best known for his research into Apple's <strong>T2 security chip</strong> as part of Team t8012:</p>
    <ul class="milestones">
      <li><span>2017</span>Built an early T2 integrity verification tool.</li>
      <li><span>Oct 2019</span>Proposed that the checkm8 bootrom exploit reached the T2, and extended ipwndfu for it.</li>
      <li><span>2020</span>Performed the team's first successful SecureROM dump.</li>
      <li><span>2020</span>Helped bring the exploit into the checkra1n jailbreak.</li>
      <li><span>2020</span>Adapted libimobiledevice to talk to the T2, and reverse engineered the USB Target Disk Mode protocol.</li>
    </ul>
  </div>
  <div class="feature-panel-aside">
    <p>When the research went public in October 2020, Rick explained to the press, including Forbes and The Register, why the flaw can't be patched in shipping Macs. He also corrected how the work had been credited.</p>
    <a href="https://blog.t8012.dev/on-bridgeos-t2-research/" class="card-link" target="_blank" rel="noopener">The team's account: On bridgeOS / T2 Research ↗</a>
  </div>
</div>

Rick is part of [Hack Different](https://github.com/hack-different), an open-source community around Apple platforms. There he maintains [apple-knowledge](https://github.com/hack-different/apple-knowledge), a machine-readable collection of reverse-engineered Apple hardware and software facts, and his most widely used project. He also contributes to The Apple Wiki.

## Research and open source

Rick publishes most of his work on [GitHub](https://github.com/rickmark). Beyond the T2 work, it falls into a few areas.

<div class="grid project-grid">
  <div class="card">
    <h3>🔐 Firmware and boot security</h3>
    <ul class="project-list">
      <li><a href="https://github.com/rickmark/mojo_thor" target="_blank" rel="noopener">mojo_thor</a> <small>2017</small> research into malware that infects the EFI and SMC firmware of MacBooks</li>
      <li><a href="https://github.com/rickmark/peiutil" target="_blank" rel="noopener">peiutil</a> <small>2017</small> converts UEFI PEI images (TE and VZ files) to PE, so they can be disassembled</li>
      <li><a href="https://github.com/rickmark/apple_ssv" target="_blank" rel="noopener">apple_ssv</a> <small>2020</small> explores macOS Signed System Volumes</li>
      <li><a href="https://github.com/rickmark/windows-bluepill" target="_blank" rel="noopener">windows-bluepill</a> <small>2022</small> breaking a system's security without breaking Secure Boot</li>
    </ul>
  </div>

  <div class="card">
    <h3>🔌 Ports, cables and radios</h3>
    <ul class="project-list">
      <li><a href="https://github.com/rickmark/badusb" target="_blank" rel="noopener">badusb</a> <small>2019</small> detects and exploits time-of-check/time-of-use gaps in USB mass storage</li>
      <li><a href="https://github.com/rickmark/lightning_strike" target="_blank" rel="noopener">lightning_strike</a> <small>2019</small> and <a href="https://github.com/rickmark/lightning_dfu" target="_blank" rel="noopener">lightning_dfu</a> <small>2021</small> study the security of the Lightning connector</li>
      <li><a href="https://github.com/rickmark/apple_utdm" target="_blank" rel="noopener">apple_utdm</a> <small>2020</small> a Linux kernel driver for Apple's USB Target Disk Mode</li>
      <li><a href="https://github.com/rickmark/apple-malicious-baseband" target="_blank" rel="noopener">apple-malicious-baseband</a> <small>2022</small> documents a malicious cellular baseband image that carried Apple's signature</li>
    </ul>
  </div>

  <div class="card">
    <h3>📚 Libraries for Apple formats and services</h3>
    <ul class="project-list">
      <li><a href="https://github.com/rickmark/libapfs" target="_blank" rel="noopener">libapfs</a> for the Apple File System</li>
      <li><a href="https://github.com/rickmark/pyxar" target="_blank" rel="noopener">pyxar</a> for XAR archives</li>
      <li><a href="https://github.com/rickmark/libiupdate" target="_blank" rel="noopener">libiupdate</a> for Apple software updates</li>
      <li><a href="https://github.com/rickmark/libicloud" target="_blank" rel="noopener">libicloud</a> for iCloud</li>
      <li><a href="https://github.com/rickmark/apple_net_recovery" target="_blank" rel="noopener">apple_net_recovery</a> for Internet Recovery</li>
      <li><a href="https://github.com/rickmark/libidevice" target="_blank" rel="noopener">libidevice</a> and <a href="https://github.com/rickmark/libxpc" target="_blank" rel="noopener">libxpc</a>, Rust reimaginings of libimobiledevice and XPC</li>
    </ul>
  </div>

  <div class="card">
    <h3>🛟 Tools that protect people</h3>
    <ul class="project-list">
      <li><a href="https://github.com/rickmark/isafety" target="_blank" rel="noopener">isafety</a> <small>2020</small> examines iPhones and iPads for security and safety threats</li>
      <li><a href="https://github.com/rickmark/chainfix" target="_blank" rel="noopener">chainfix</a> <small>2024</small> checks and repairs Keychain and iCloud Keychain</li>
      <li><a href="https://github.com/lwm-luminx/hedonism_bot" target="_blank" rel="noopener">hedonism_bot</a> where photographers upload photos. It uses the same Postgres, pgvector, and embedding approach as Garage to find and group faces without naming anyone, so people can find and download the photos they appear in.</li>
    </ul>
  </div>
</div>

### In the organizations he runs

Rick also owns the [Hack Different](https://github.com/hack-different) and [Team t8012](https://github.com/t8012) organizations on GitHub. Besides apple-knowledge, their projects include:

<ul class="project-columns">
  <li><a href="https://github.com/hack-different/webmuxd" target="_blank" rel="noopener">webmuxd</a> and <a href="https://github.com/hack-different/go-webmuxd" target="_blank" rel="noopener">go-webmuxd</a>, a PoC of an attack where a browser may be able to access iPhone sync data</li>
  <li><a href="https://github.com/hack-different/demuxusb" target="_blank" rel="noopener">demuxusb</a>, a tool to decode iDevice USB capture sessions</li>
  <li><a href="https://github.com/hack-different/smcutil" target="_blank" rel="noopener">smcutil</a>, a decoder for Apple's SMC payloads (T1 and prior)</li>
  <li><a href="https://github.com/hack-different/efivalidate" target="_blank" rel="noopener">efivalidate</a> for validating the firmware of Macs up to the T1</li>
  <li><a href="https://github.com/hack-different/libapplefw" target="_blank" rel="noopener">libapplefw</a>, generic utils for Apple firmware images</li>
  <li><a href="https://github.com/hack-different/go-aapl-integrity" target="_blank" rel="noopener">go-aapl-integrity</a> and <a href="https://github.com/t8012/cnklverify" target="_blank" rel="noopener">cnklverify</a> for Apple's integrity formats (img4, chunklists, trust caches)</li>
  <li><a href="https://github.com/hack-different/secure_emu" target="_blank" rel="noopener">secure_emu</a>, which runs portions of SecureROM under the Unicorn emulator</li>
  <li><a href="https://github.com/hack-different/mootool" target="_blank" rel="noopener">mootool</a>, generic parsing of Apple security state information including LocalPolicy, FDR, Signed APTickets, etc.</li>
  <li><a href="https://github.com/hack-different/yolo_dsc" target="_blank" rel="noopener">yolo_dsc</a> for extracting the dyld shared cache</li>
  <li><a href="https://github.com/hack-different/symbol-server" target="_blank" rel="noopener">symbol-server</a> for annotating Apple symbols</li>
  <li><a href="https://github.com/hack-different/xnudex" target="_blank" rel="noopener">xnudex</a> for indexing XNU OS images (they were getting too large in <code>apple-knowledge</code>)</li>
  <li><a href="https://github.com/hack-different/kext-kmem" target="_blank" rel="noopener">kext-kmem</a>, a kernel extension for reading and writing kernel memory, replacing /dev/kmem</li>
  <li><a href="https://github.com/hack-different/homebrew-jailbreak" target="_blank" rel="noopener">homebrew-jailbreak</a>, a Homebrew tap of research tools</li>
  <li><a href="https://github.com/hack-different/newosxbook-tools" target="_blank" rel="noopener">newosxbook-tools</a>, which packages Jonathan Levin's tools for it</li>
  <li><a href="https://github.com/hack-different/libibackup" target="_blank" rel="noopener">libibackup</a> for iOS backups</li>
  <li><a href="https://github.com/hack-different/apple-diagnostics-format" target="_blank" rel="noopener">apple-diagnostics-format</a> for Apple's wireless diagnostics files</li>
  <li><a href="https://github.com/hack-different/apple-baseband" target="_blank" rel="noopener">apple-baseband</a> for the modem baseband</li>
  <li><a href="https://github.com/hack-different/uarp" target="_blank" rel="noopener">uarp</a> for Apple's accessory firmware update protocol</li>
  <li>From the T2 work: <a href="https://github.com/t8012/pongo-flash" target="_blank" rel="noopener">pongo-flash</a>, a flash storage driver for checkra1n's pongoOS, and <a href="https://github.com/t8012/RemoteServiceDiscovery" target="_blank" rel="noopener">RemoteServiceDiscovery</a>, a reverse-engineered rewrite of Apple's framework of that name</li>
</ul>

He also open-sourced [AudienceKit](https://github.com/audience-kit), a generalization of Hot Mess, his 2015 app that indexed subcultures by their people, places, and events. AudienceKit has its own API, admin interface, and Swift and Ruby SDKs.

## Contributions to other projects

Rick has had pull requests merged in more than 25 projects outside his own. Among them:

<div class="grid contrib-grid">
  <div class="card">
    <h3>Apple platform tooling</h3>
    <p>Mach-O fileset support and new segment types in Homebrew's <a href="https://github.com/Homebrew/ruby-macho" target="_blank" rel="noopener">ruby-macho</a> (five merged PRs), T2 support in <a href="https://github.com/libimobiledevice/usbmuxd/pull/141" target="_blank" rel="noopener">usbmuxd</a>, Linux fixes to <a href="https://github.com/h0m3us3r/ipwndfu/pull/1" target="_blank" rel="noopener">ipwndfu</a>, build work on checkra1n's <a href="https://github.com/checkra1n/PongoOS/pull/14" target="_blank" rel="noopener">PongoOS</a>, pkg-config support in <a href="https://github.com/sbingner/ldid/pull/3" target="_blank" rel="noopener">ldid</a>, the convert verb in <a href="https://github.com/0xbf00/dmglib/pull/2" target="_blank" rel="noopener">dmglib</a>, and firmware sources in Acidanthera's <a href="https://github.com/acidanthera/MacInfoPkg/pull/16" target="_blank" rel="noopener">MacInfoPkg</a>.</p>
  </div>
  <div class="card">
    <h3>Reverse engineering</h3>
    <p>Universal macOS builds of the <a href="https://github.com/capstone-engine/capstone/pull/2221" target="_blank" rel="noopener">Capstone</a> disassembler, a fix to Vector 35's <a href="https://github.com/Vector35/workflow_objc/pull/57" target="_blank" rel="noopener">Objective-C workflow</a> for Binary Ninja, and an easier install for <a href="https://github.com/platomav/MEAnalyzer/pull/7" target="_blank" rel="noopener">MEAnalyzer</a>, Intel's Management Engine analyzer.</p>
  </div>
  <div class="card">
    <h3>Security</h3>
    <p><code>OpenSSL::BN#abs</code> in Ruby's <a href="https://github.com/ruby/openssl/pull/430" target="_blank" rel="noopener">openssl</a> library, removing unsafe OpenSSL patches from <a href="https://github.com/GemHQ/money-tree/pull/43" target="_blank" rel="noopener">money-tree</a>, and a stricter content security policy for Dropbox's <a href="https://github.com/dropbox/merou" target="_blank" rel="noopener">merou</a> permissions system.</p>
  </div>
  <div class="card">
    <h3>Data and infrastructure</h3>
    <p>The build and validation tests for <a href="https://github.com/littlebyteorg/appledb" target="_blank" rel="noopener">AppleDB</a> (four merged PRs), universal macOS build instructions for <a href="https://github.com/facebook/zstd/pull/3568" target="_blank" rel="noopener">Zstandard</a>, fixes to <a href="https://github.com/Homebrew/brew/pull/12822" target="_blank" rel="noopener">Homebrew</a>, <a href="https://github.com/sds/overcommit/pull/777" target="_blank" rel="noopener">overcommit</a> and <a href="https://github.com/q9f/keccak.rb/pull/39" target="_blank" rel="noopener">keccak.rb</a>, and <a href="https://github.com/meshtastic/firmware/pull/5699" target="_blank" rel="noopener">Meshtastic</a> firmware dev containers.</p>
  </div>
  <div class="card">
    <h3>SDR and ham radio</h3>
    <p>Ported bladeRF and <a href="https://github.com/Nuand/libbladeRF" target="_blank" rel="noopener">libbladeRF</a>, <code>android-sdr-kit</code>, and <a href="https://www.sdrpp.org" target="_blank" rel="noopener">SDR++</a> to Android (<a href="https://github.com/Nuand/bladeRF/pull/1063" target="_blank" rel="noopener">#1063</a>). He also wrote <a href="https://github.com/rickmark/meshtastic-map-manager" target="_blank" rel="noopener">meshtastic-map-manager</a> for managing Meshtastic map data.</p>
  </div>
</div>

## Outside of work

Away from the keyboard, Rick makes documentary film and photography centered on the LGBT community.

## Why Garage

Garage brings that security background to AI. It makes your own documents, code, and messages searchable by your AI assistant. The database, the index, and, by default, the models all run on your computer, and Garage itself never sends your messages to another computer. Your AI assistant receives only the excerpts it asks for, and what happens to them after that depends on the assistant; the [privacy page]({{ '/privacy.html' | relative_url }}) covers the details. Garage is open source, so you can check all of this for yourself.

<div class="grid closing-grid">
  <div class="card card-accent">
    <span class="card-icon">💼</span>
    <h3>Work with Rick</h3>
    <p>Rick is available for hire for AI security, privacy engineering, and security research roles, remote or hybrid. If you or your team could use help with software like this, get in touch.</p>
    <a href="https://linkedin.com/in/penwellr" class="card-link" target="_blank" rel="noopener">LinkedIn ↗</a>
  </div>
  <div class="card">
    <span class="card-icon">💛</span>
    <h3>Support the project</h3>
    <p>Garage is free. If it's useful to you, you can support Rick's work on Patreon, and you can report bugs, suggest features or send pull requests on GitHub.</p>
    <a href="https://www.patreon.com/rickmark" class="card-link" target="_blank" rel="noopener">Patreon ↗</a>
    <a href="{{ '/contributing.html' | relative_url }}" class="card-link">How to contribute →</a>
  </div>
</div>
