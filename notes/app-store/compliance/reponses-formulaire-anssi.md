# Réponses à reporter dans le formulaire ANSSI

Formulaire officiel : « Déclaration et demande d'autorisation d'opérations relatives à un moyen de cryptologie »
(fichier `crypto_declaration-demande_autorisation_operations_annexe1_v2.pdf`), à télécharger sur
https://cyber.gouv.fr/reglementation/reglementation-identite-confiance-numerique/controles-reglementaires-cryptographie/controle-moyen-de-cryptologie/controle-reglementaire-cryptographie-formulaires/

Le formulaire n'a pas pu être téléchargé depuis l'environnement de préparation. Les réponses ci-dessous suivent les
rubriques qu'impose l'arrêté du 29 janvier 2015 ; reporter chaque réponse dans la case correspondante du PDF. Les
passages entre crochets sont à compléter par le déclarant.

## 1. Nature de l'opération

| Opération | Formalité | Réponse |
|---|---|---|
| Fourniture en France | Déclaration | **Oui, cocher** |
| Importation depuis un État non membre de l'Union européenne (États-Unis) | Déclaration | **Oui, cocher** (téléchargement direct depuis garagerag.app) |
| Transfert depuis un État membre de l'UE | — | Non (voir la note juridique du README) |
| Transfert vers un État membre / exportation hors UE depuis la France | Autorisation | Non : aucune opération depuis la France |
| Demande de classement « grand public » (annexe II, point 3, du décret n° 2007-663) | — | Non (utile seulement pour exporter depuis la France) |

## 2. Identification du déclarant

- Qualité : personne physique ; développeur et éditeur du logiciel
- Nom : MARK-PENWELL
- Prénom : Rick
- Adresse : [adresse postale complète], États-Unis
- Téléphone : [+1 …]
- Courriel : [adresse de contact à utiliser avec l'ANSSI]
- Numéro SIREN / SIRET : sans objet (déclarant non établi en France)
- Personne chargée du dossier : le déclarant

## 3. Identification du moyen de cryptologie

- Dénomination commerciale : Garage RAG
- Version : 1.5 (build [numéro])
- Éditeur / fabricant : Rick Mark-Penwell (États-Unis)
- Type : logiciel
- Plateforme : macOS 14 ou ultérieur, Apple Silicon
- Catégorie : logiciel applicatif grand public de recherche documentaire personnelle ; la cryptologie est accessoire (protection des communications par TLS)

## 4. Fonctions de cryptologie

- Confidentialité : **oui**, limitée au chiffrement des communications réseau par le protocole standard TLS (client uniquement), et au déchiffrement de documents PDF chiffrés appartenant à l'utilisateur
- Authentification / intégrité : oui (certificats TLS, SHA-256, SCRAM-SHA-256, Ed25519)
- Chiffrement de données stockées : non
- Algorithme propriétaire : non
- Algorithmes : AES-128/256 (GCM, CBC), ChaCha20-Poly1305, ECDHE (X25519, P-256, P-384), RSA ≥ 2048, ECDSA, Ed25519, SHA-256/384, RC4 (lecture de PDF anciens uniquement)
- Longueur maximale des clés symétriques : 256 bits
- Gestion des clés : clés de session éphémères, aucune clé à long terme, aucun séquestre, l'éditeur ne détient aucune clé
- Modifiable par l'utilisateur : non
- Bibliothèques : macOS (URLSession, Security, CryptoKit), OpenSSL 3.4.7, cryptography 43.0.3, BoringSSL (dans grpcio 1.83.1 et grpc-swift, non utilisé)

Détail complet : « Annexe technique » jointe (`annexe-technique-garage-1.5.pdf`).

## 5. Modalités de commercialisation

Gratuit, grand public, disponible dans le monde entier sans restriction, installé par l'utilisateur sans assistance,
distribué par le Mac App Store d'Apple et par téléchargement direct sur https://garagerag.app. Code source public
(licence MIT).

## 6. Engagement et signature

Signature manuscrite du déclarant, lieu et date. Scanner le formulaire signé en PDF.
