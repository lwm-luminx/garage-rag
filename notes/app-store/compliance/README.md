# France encryption declaration for Garage RAG 1.5

Prepared 2026-09-27. Nothing has been sent to ANSSI or uploaded to App Store Connect.

## What App Store Connect wants

Apple's reference table ("Export compliance documentation for encryption") has three cases:

| Your app's encryption | Documentation |
|---|---|
| Only Apple's OS crypto | None |
| Industry-standard algorithms not provided by the OS | **French encryption declaration**, only if the app is on the App Store in France |
| Proprietary algorithms | US CCATS plus the French declaration |

Garage is the middle row: it bundles OpenSSL (Python), a second OpenSSL inside the `cryptography` wheel, and
BoringSSL (grpcio, grpc-swift), all standard algorithms. So no US document is needed, and the only upload is the
French declaration.

In App Store Connect: **Apps → Garage RAG → App Information → App Encryption Documentation → (+)**, answer:

1. Algorithm type: **"Standard encryption algorithms instead of, or in addition to, using or accessing the encryption
   within Apple's operating system."**
2. Available in France: **Yes**, then **Choose File** and upload the French declaration PDF (see step 5 below).

Apple reviews it (it says about two business days) and then shows a **key value** next to the approved document. That
value goes into `macapp/Sources/GarageApp/Info.plist` as `ITSEncryptionExportComplianceCode`, beside the existing
`ITSAppUsesNonExemptEncryption = true`, so later uploads stop asking. That is a one-line PR once the key exists.

## The files here

| File | Language | What it is |
|---|---|---|
| `reponses-formulaire-anssi.md` | French | Field-by-field answers to copy into ANSSI's official form |
| `annexe-technique-garage-1.5.pdf` | French | Technical annex: every crypto library, what it does, algorithms, key lengths, key management. Attach to the form |
| `annexe-technique-garage-1.5.html` | French | Source of the PDF, for filling the yellow placeholders |
| `courriel-anssi.md` | French | Cover email to ANSSI |

The yellow placeholders in the annex are the build number, place, date and signature. Fill them in the HTML and
print to PDF, or tell the thread the build number and place and it will regenerate the PDF.

## Steps

1. **Download the official form** from ANSSI's forms page:
   https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/
   (file `crypto_declaration-demande_autorisation_operations_annexe1_v2.pdf`). This environment could not download
   it, so the answers follow the sections the 2015 arrêté requires rather than the PDF's exact box numbers.
   Check each box against `reponses-formulaire-anssi.md`.
2. **Fill in** your postal address, phone, email and the build number. Tick *fourniture* and *importation*
   (declaration). Do not request *classement grand public*; it only matters for exporting from France.
3. **Sign** the form by hand and scan it.
4. **Email ANSSI** at `controle@ssi.gouv.fr` with the subject `[formalités] Garage – Garage RAG`, attaching the
   signed scan, the filled electronic form and the annex (text in `courriel-anssi.md`). Postal alternative, two
   copies: ANSSI / SDE / PSS / Bureau Contrôles Réglementaires, 51 boulevard de La Tour-Maubourg, 75700 Paris 07 SP.
5. **Upload to Apple** one PDF combining the signed form, the annex and, when it arrives, ANSSI's *attestation de
   déclaration*. Developer reports disagree on whether Apple accepts the form without ANSSI's attestation (one says
   the completed form was enough; a French law firm says Apple asks for the attestation). Two ways to handle it:
   - Upload the signed form, annex and a copy of your sent email now, and replace it if Apple rejects it.
   - Or leave France out of 1.5's availability until the attestation arrives, then add it.
6. **Add the key** Apple issues to `Info.plist` as `ITSEncryptionExportComplianceCode`.

## Things a lawyer should confirm

1. **Whether a declaration is needed at all.** Apple's table says yes for bundled standard crypto. French law
   (LCEN art. 30) requires a declaration for supplying or importing a means that does more than authentication or
   integrity, and TLS confidentiality counts. The decree's exemption list does not obviously cover general-purpose
   TLS software. A lawyer could say whether "crypto incidental to a non-crypto product" is exempt; I did not find a
   rule that says so.
2. **Who declares, and for which operation.** Rick is a US individual with no French establishment. App Store sales
   in France go through Apple's Irish entity, so the App Store channel may be an intra-EU transfer rather than an
   import, while the direct download from garagerag.app is an import from the US. The draft ticks *fourniture* and
   *importation* to cover both; a lawyer should confirm that is the right pair.
3. **Signing as an individual** with a US address, and whether ANSSI expects a French or EU contact.
4. **Future versions.** A declaration covers the declared means. Whether 1.5.x or 1.6 needs a new declaration when
   library versions change (OpenSSL, grpcio) but the cryptographic functions do not.
5. **Accuracy.** The declarant signs for the technical content. False or missing declarations carry penalties
   under LCEN art. 35 (fine and imprisonment for failing to declare). Rick should read the annex before signing;
   `release-review/openssl-audit.md` is the English source for most of it.
6. **US side.** Apple needs no US document here. Whether Rick owes BIS anything for mass-market standard crypto
   (the source is public under MIT, which may put it outside the EAR) is a separate question from Apple's.

## Facts the annex relies on (checked in the repo on main at 1f524ed)

- OpenSSL 3.4.7 static in Python 3.13.15 (`ext/openssl/openssl.MODULE.bazel`, `ext/python`).
- `cryptography` 43.0.3, `grpcio` 1.83.1, `pyjwt` 2.13.0 (`garage_python/uv.lock`).
- gRPC plaintext on Unix sockets, Postgres built without SSL, SCRAM auth (`release-review/openssl-audit.md`).
- CryptoKit SHA-256 for model downloads (`macapp/Sources/ModelDownloadClient/ModelDownloaderEngine.swift`).
- Keychain for the Postgres password and the LM Studio token.
- Sparkle in the Developer ID build only.
- Minimum macOS 14, arm64 only, MIT licence, free.
- Inferred, not checked in code: the exact TLS cipher suites (the annex lists what macOS and OpenSSL 3.4 negotiate by
  default), and that the repo is public (the annex says the source is public).

## Sources

- Apple, export compliance documentation table: https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/
- Apple, upload steps and key value: https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation
- Apple, overview (France paragraph): https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance
- ANSSI, forms and submission: https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/
- ANSSI, procedures: https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-rglementaire-cryptographie-demarches/
- Décret n° 2007-663: https://www.legifrance.gouv.fr/loda/id/JORFTEXT000000646995
- Arrêté du 29 janvier 2015 (form contents): https://www.legifrance.gouv.fr/loda/id/JORFTEXT000030255024
- Developer experience with Apple and ANSSI: https://gist.github.com/chrisballinger/7239932
- Domanski avocat on app declarations: https://www.domanski-avocat.com/declaration-anssi-dune-application-mobile-integrant-un-outil-de-chiffrement
