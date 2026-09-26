---
layout: default
title: About the creator
description: Rick Mark-Penwell, the creator of Garage, is a security and AI engineer, formerly of Meta, Coinbase, Dropbox and Microsoft, known for his research into Apple's T2 chip.
---

# About the creator

Garage is written and maintained by **Rick Mark-Penwell**.

Rick is a security and AI engineer and a hardware security researcher who has worked on Apple platforms since 2007. His Apple developer account dates from then and still carries his prior name, Richard Penwell, so that's the name on Garage's Developer ID signature. Rick Mark and Richard Penwell are the same person, and Garage's copyright uses the hyphenated name to make that clear.

## Career

Rick has spent more than fifteen years in security engineering, most recently using AI where it genuinely helps.

- **Meta**, Privacy Engineer (2023 to 2025). He built PrivacyBrain, an LLM derived from Llama that evaluated privacy incidents, reviews and FTC commitments across millions of records, and Project Terminus, which linked incidents to their root causes and replaced months of manual investigation with consistent measures. He also wrote an LLVM-bitcode scanner for sensitive iOS and macOS APIs, and contributed to the design of Llama 4.
- **Coinbase**, Security Architect (2021 to 2022).
- **Dropbox**, Senior Security Engineer (2017 to 2019). He worked on corporate authentication, key management and Windows security in the datacenters, and open-sourced efivalidate for checking Mac firmware.
- **Uber Advanced Technologies Group**, Senior Security Engineer (2017).
- **Jet.com**, Senior Software Security Engineer (2016). He was the company's first security engineer, securing what was then the largest e-commerce site on Azure.
- **Bloomberg**, Senior Web Application Developer (2015 to 2016), on Bloomberg's legal research platform.
- **Microsoft**, Software Engineer and then Azure Security SDE II (2010 to 2015). He did threat modeling and penetration testing for Azure, automated security health reporting across more than 150 teams, and worked on the Windows Data Classification Toolkit. He holds a patent on [detecting and preventing phishing attacks](https://patents.google.com/patent/US20160006760A1).

He also founded **Hot Mess** and **AudienceKit**, products that apply social science to in-person community (more below).

## Apple security research

He is best known for his research into Apple's **T2 security chip** as part of Team t8012:
- He built an early T2 integrity verification tool in 2017.
- In October 2019 he proposed that the checkm8 bootrom exploit reached the T2, and extended ipwndfu for it.
- In 2020 he performed the team's first successful SecureROM dump.
- He helped bring the exploit into the checkra1n jailbreak.
- He adapted libimobiledevice to talk to the T2, and reverse engineered the USB Target Disk Mode protocol.

When the research went public in October 2020, Rick explained to the press, including Forbes and The Register, why the flaw can't be patched in shipping Macs. He also corrected how the work had been credited. The team's own account is [On bridgeOS / T2 Research](https://blog.t8012.dev/on-bridgeos-t2-research/).

Rick is part of [Hack Different](https://github.com/hack-different), an open-source community around Apple platforms. There he maintains [apple-knowledge](https://github.com/hack-different/apple-knowledge), a machine-readable collection of reverse-engineered Apple hardware and software facts. He also contributes to The Apple Wiki.

## Research and open source

Rick publishes most of his work on [GitHub](https://github.com/rickmark). Beyond the T2 work, it falls into a few areas.

**Firmware and boot security.**
- [mojo_thor](https://github.com/rickmark/mojo_thor) (2017) is research into malware that infects the EFI and SMC firmware of MacBooks.
- [peiutil](https://github.com/rickmark/peiutil) (2017) converts UEFI PEI images (TE and VZ files) to PE, so they can be disassembled.
- [apple_ssv](https://github.com/rickmark/apple_ssv) (2020) explores macOS Signed System Volumes.
- [windows-bluepill](https://github.com/rickmark/windows-bluepill) (2022) looks at breaking a system's security without breaking Secure Boot.

**Ports, cables and radios.**
- [badusb](https://github.com/rickmark/badusb) (2019) detects and exploits time-of-check/time-of-use gaps in USB mass storage.
- [lightning_strike](https://github.com/rickmark/lightning_strike) (2019) and [lightning_dfu](https://github.com/rickmark/lightning_dfu) (2021) study the security of the Lightning connector.
- [apple_utdm](https://github.com/rickmark/apple_utdm) (2020) is a Linux kernel driver for Apple's USB Target Disk Mode.
- [apple-malicious-baseband](https://github.com/rickmark/apple-malicious-baseband) (2022) documents a malicious cellular baseband image that carried Apple's signature.

**Libraries for Apple formats and services.** [libapfs](https://github.com/rickmark/libapfs) for the Apple File System, [pyxar](https://github.com/rickmark/pyxar) for XAR archives, [libiupdate](https://github.com/rickmark/libiupdate) for Apple software updates, [libicloud](https://github.com/rickmark/libicloud) for iCloud, [apple_net_recovery](https://github.com/rickmark/apple_net_recovery) for Internet Recovery, and Rust reimaginings of libimobiledevice ([libidevice](https://github.com/rickmark/libidevice)) and XPC ([libxpc](https://github.com/rickmark/libxpc)).

**Tools that protect people.**
- [isafety](https://github.com/rickmark/isafety) (2020) examines iPhones and iPads for security and safety threats.
- [chainfix](https://github.com/rickmark/chainfix) (2024) checks and repairs Keychain and iCloud Keychain.

**In the organizations he runs.** Rick also owns the [Hack Different](https://github.com/hack-different) and [Team t8012](https://github.com/t8012) organizations on GitHub. Besides apple-knowledge, their projects include:
- [webmuxd](https://github.com/hack-different/webmuxd) and [go-webmuxd](https://github.com/hack-different/go-webmuxd), which talk to iPhones and iPads from a web browser over WebUSB, and [demuxusb](https://github.com/hack-different/demuxusb), which analyzes their USB sessions;
- [smcutil](https://github.com/hack-different/smcutil) for Apple's SMC payloads, [efivalidate](https://github.com/hack-different/efivalidate) for validating the firmware of Macs up to the T1, and [libapplefw](https://github.com/hack-different/libapplefw) for Apple firmware images;
- [go-aapl-integrity](https://github.com/hack-different/go-aapl-integrity) and [cnklverify](https://github.com/t8012/cnklverify) for Apple's integrity formats (img4, chunklists, trust caches), and [secure_emu](https://github.com/hack-different/secure_emu), which runs SecureROM under the Unicorn emulator;
- [mootool](https://github.com/hack-different/mootool) for Mach-O files, [yolo_dsc](https://github.com/hack-different/yolo_dsc) for extracting the dyld shared cache, [symbol-server](https://github.com/hack-different/symbol-server) for Apple symbols, [xnudex](https://github.com/hack-different/xnudex) for indexing XNU OS images, and [kext-kmem](https://github.com/hack-different/kext-kmem), a kernel extension for reading and writing kernel memory;
- [homebrew-jailbreak](https://github.com/hack-different/homebrew-jailbreak), a Homebrew tap of research tools, and [newosxbook-tools](https://github.com/hack-different/newosxbook-tools), which packages Jonathan Levin's tools for it;
- [libibackup](https://github.com/hack-different/libibackup) for iOS backups, [apple-diagnostics-format](https://github.com/hack-different/apple-diagnostics-format) for Apple's wireless diagnostics files, [apple-baseband](https://github.com/hack-different/apple-baseband) for the modem baseband, and [uarp](https://github.com/hack-different/uarp) for Apple's accessory firmware update protocol;
- from the T2 work, [pongo-flash](https://github.com/t8012/pongo-flash), a flash storage driver for checkra1n's pongoOS, and [RemoteServiceDiscovery](https://github.com/t8012/RemoteServiceDiscovery), a reverse-engineered rewrite of Apple's framework of that name.

He also runs [AudienceKit](https://github.com/audience-kit), a generalization of Hot Mess, his 2015 app that indexed subcultures by their people, places and events. AudienceKit has its own API, admin interface, and Swift and Ruby SDKs. He also built [hedonism_bot](https://github.com/lwm-luminx/hedonism_bot), where photographers upload photos. It uses the same Postgres, pgvector and embedding approach as Garage to find and group faces without naming anyone, so people can find and download the photos they appear in.

His most widely used project is [apple-knowledge](https://github.com/hack-different/apple-knowledge), mentioned above, with over 1,400 stars on GitHub.

**Contributions to other projects.** Rick has had pull requests merged in more than 25 projects outside his own. Among them:
- **Apple platform tooling:** Mach-O fileset support and new segment types in Homebrew's [ruby-macho](https://github.com/Homebrew/ruby-macho) (five merged PRs), T2 support in [usbmuxd](https://github.com/libimobiledevice/usbmuxd/pull/141), Linux fixes to [ipwndfu](https://github.com/h0m3us3r/ipwndfu/pull/1), build work on checkra1n's [PongoOS](https://github.com/checkra1n/PongoOS/pull/14), pkg-config support in [ldid](https://github.com/sbingner/ldid/pull/3), the convert verb in [dmglib](https://github.com/0xbf00/dmglib/pull/2), and firmware sources in Acidanthera's [MacInfoPkg](https://github.com/acidanthera/MacInfoPkg/pull/16).
- **Reverse engineering:** universal macOS builds of the [Capstone](https://github.com/capstone-engine/capstone/pull/2221) disassembler, a fix to Vector 35's [Objective-C workflow](https://github.com/Vector35/workflow_objc/pull/57) for Binary Ninja, and an easier install for [MEAnalyzer](https://github.com/platomav/MEAnalyzer/pull/7), Intel's Management Engine analyzer.
- **Security:** `OpenSSL::BN#abs` in Ruby's [openssl](https://github.com/ruby/openssl/pull/430) library, removing unsafe OpenSSL patches from [money-tree](https://github.com/GemHQ/money-tree/pull/43), and a stricter content security policy for Dropbox's [merou](https://github.com/dropbox/merou) permissions system.
- **Data and infrastructure:** the build and validation tests for [AppleDB](https://github.com/littlebyteorg/appledb) (four merged PRs), universal macOS build instructions for [Zstandard](https://github.com/facebook/zstd/pull/3568), fixes to [Homebrew](https://github.com/Homebrew/brew/pull/12822), [overcommit](https://github.com/sds/overcommit/pull/777) and [keccak.rb](https://github.com/q9f/keccak.rb/pull/39), and [Meshtastic](https://github.com/meshtastic/firmware/pull/5699) firmware dev containers.

He also wrote [meshtastic-map-manager](https://github.com/rickmark/meshtastic-map-manager) for managing Meshtastic map data.

## Outside of work

Away from the keyboard, Rick makes documentary film and photography centered on the LGBT community.

## Why Garage

Garage brings that security background to AI. It makes your own documents, code and messages searchable by your AI assistant. The database, the index and, by default, the models all run on your Mac, and Garage itself never sends your messages to another computer. Your AI assistant receives only the excerpts it asks for, and what happens to them after that depends on the assistant; the [privacy page]({{ '/privacy.html' | relative_url }}) covers the details. Garage is open source, so you can check all of this for yourself.

## Work with Rick

Rick is available for hire, for AI security, privacy engineering and security research roles, remote or hybrid. If you or your team could use help with software like this, get in touch on [LinkedIn](https://linkedin.com/in/penwellr).

## Support the project

Garage is free. If it's useful to you, you can support Rick's work on [Patreon](https://www.patreon.com/rickmark), and you can report bugs, suggest features or send pull requests on [GitHub](https://github.com/rickmark/garage-rag).

## Elsewhere

[GitHub](https://github.com/rickmark) · [LinkedIn](https://linkedin.com/in/penwellr)
