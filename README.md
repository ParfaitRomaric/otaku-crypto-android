# otaku-crypto-android — liaison Kotlin de matrix-sdk-crypto (étape 5 bis de G1)

Contenu prêt à copier dans un **dépôt GitHub public dédié** (D-238, D-299 Q1), préparé par Kurapika le 2026-10-20, à relire par Bulma (CI) puis Killua (sécurité). Rien n'a encore été exécuté : la première compilation aura lieu dans ce dépôt (aucune chaîne Rust sur le poste, ADR-0009).

## Ce que fait le dépôt

- Récupère `matrix-org/matrix-rust-sdk` au **commit épinglé** du tag `matrix-sdk-crypto-0.19.1` (même version de matrix-sdk-crypto que `@matrix-org/matrix-sdk-crypto-wasm` 18.9.0 sur le web, G1 §6.6).
- Applique `patches/0001-ffi-identity-based-strategy.patch` : expose la stratégie de partage « appareils signés par leur compte » (`EncryptionSettings.identity_based_strategy`, faux par défaut) et l'indicateur `Device.is_cross_signed_by_owner` (G1 §6.1, TEC-08, MM-E1). Le même correctif est à proposer en amont tel quel.
- Compile `matrix-sdk-crypto-ffi` pour **arm64-v8a et armeabi-v7a seulement** avec l'outil `xtask` du dépôt amont (cargo-ndk, binaires dépouillés, sources Kotlin générées par UniFFI), avec Rust (imposé aussi par `RUSTUP_TOOLCHAIN`), cargo-ndk et le NDK figés (`UPSTREAM.env`, NDK installé par `sdkmanager` s'il manque sur la machine) ; `cargo fetch --locked`, puis compilation hors ligne (`CARGO_NET_OFFLINE`) et contrôle que `Cargo.lock` n'a pas bougé (l'outil `xtask` et cargo-ndk ne passent pas `--locked`).
- Fait **deux compilations indépendantes** (deux machines GitHub) et exige des octets identiques ; produit la liste des paquets Rust liés et leurs licences (`THIRD_PARTY_CRATES.txt`, G1 §3.4).
- Sur un tag `vX.Y.Z` seulement : archive déterministe, **attestation de provenance** Sigstore (`actions/attest-build-provenance`), publication en « release » GitHub (`--verify-tag`) avec l'empreinte SHA-256 de l'archive et `SHA256SUMS.build` (empreinte de chaque fichier, aussi inclus dans l'archive). Le tag est contrôlé (`vX.Y.Z[-otaku.N]`) avant tout usage.
- **Aucun cache**, volontairement : chaque compilation part des seules épingles (pas d'empoisonnement de cache, rien d'hérité d'une exécution précédente), pour environ 3 minutes d'installation par tâche.

Aucun secret : seul le jeton automatique `GITHUB_TOKEN`, en lecture seule partout sauf dans la tâche de publication (`contents: write`, `id-token: write`, `attestations: write`). Actions épinglées par commit, mêmes versions que le dépôt Otaku (checkout 7.0.1, upload-artifact 7.0.1), plus download-artifact 8.0.2 et attest-build-provenance 4.2.2 (publiées depuis plus de 7 jours).

## Durée et coût estimés (à confirmer à la première exécution)

- Par tâche de compilation (les deux en parallèle, machine standard 4 cœurs) : Rust et cargo-ndk 3 min, téléchargement des paquets 1 min, `xtask` et `uniffi-bindgen` pour la machine 3 min, `matrix-sdk-crypto-ffi` en profil `release` 8 à 12 min par architecture : **environ 25 à 35 min** (limite fixée à 90 min).
- Comparaison 1 min, publication 2 min. Environ 60 à 75 minutes-machine par exécution, **gratuites** (dépôt public, exécuteurs standard) ; artefacts conservés 7 jours (quelques dizaines de Mo).

## Fichiers

| Fichier | Rôle |
|---|---|
| `.github/workflows/build.yml` | Compilation ×2, comparaison, attestation et publication sur tag |
| `UPSTREAM.env` | Épingles : dépôt et commit amont, Rust 1.99.0, cargo-ndk 4.1.2, NDK 28.2.13676358, cibles |
| `patches/0001-ffi-identity-based-strategy.patch` | Correctif (vérifié : s'applique au commit épinglé par `git apply --check`) |
| `scripts/build.sh` | Vérifie le commit, applique les correctifs, compile, liste les licences, empreintes |
| `scripts/elf-sections.py` | Diagnostic : empreinte de chaque section ELF, comparée seulement si les deux compilations diffèrent |
| `scripts/package.sh` | Archive `tar.gz` déterministe (noms triés, dates et propriétaires fixes, gzip sans horodatage) |
| `LICENSE` | **À ajouter** : texte de la licence Apache 2.0 (celle du code amont) |

## Ce que le fondateur fait (une fois)

1. Créer le dépôt public (par exemple `otaku-crypto-android`) sous le compte de l'organisation ou du fondateur, sans modèle ; y copier ce dossier (sans ce `README.md` ou en l'adaptant) et le fichier `LICENSE`.
2. Réglages (*Settings*) :
   - *Actions → General* : « Allow actions created by GitHub » seulement (le workflow n'utilise que `actions/*`) et « Require actions to be pinned to a full-length commit SHA » ; « Require approval for all external contributors » ; *Workflow permissions* : « Read repository contents and packages permissions », sans « Allow GitHub Actions to create and approve pull requests ».
   - *General → Releases* : activer « Enable release immutability » (une release publiée ne peut plus être modifiée ni recevoir d'autre fichier).
   - *Rules → Rulesets* : branche `main` (demande de fusion obligatoire, pas de poussée forcée ni de suppression) ; tags `v*` (création, mise à jour et suppression réservées au fondateur, en contournement nommé).
   - Aucun secret, aucune variable, aucun environnement à créer.
3. Pousser sur `main` (déclenche une compilation sans publication), vérifier que les deux compilations sont identiques, puis créer et pousser le tag `v0.19.1-otaku.2` (`v0.19.1-otaku.1` a été poussé sur un commit qui ne compilait pas, sans release, et ne se déplace pas) ; relever l'URL et le SHA-256 de l'archive publiés pour les transmettre au coordinateur (empreinte figée côté Otaku).

## Côté Otaku (plus tard, `packages/crypto/android`, avec Bulma)

- L'ancre de confiance est l'**empreinte SHA-256 figée dans le dépôt Otaku** (avec l'URL figée de la release, tag compris) : le build EAS télécharge l'archive et vérifie cette empreinte avant extraction (tâche Gradle qui échoue sinon) ; JNA par Maven Central avec `gradle/verification-metadata.xml`.
- À chaque changement d'épingle, dans la demande de fusion Otaku (tâche de CI dédiée, avant d'écrire la nouvelle empreinte) : `gh attestation verify <archive> --repo <propriétaire>/otaku-crypto-android --signer-workflow <propriétaire>/otaku-crypto-android/.github/workflows/build.yml --source-ref refs/tags/<tag> --deny-self-hosted-runners`, puis comparaison de l'empreinte avec le fichier `.sha256` de la release.
- Règles R8/ProGuard pour JNA et les classes UniFFI (G1 §4.2).
- Mise à jour de sécurité : veille des avis matrix-org ; nouvelle épingle = PR relue + nouveau tag (0,5 à 1 jour, G1 §6.1).

## Reproductibilité (après l'échec du 2026-10-22)

Première exécution : fichiers Kotlin et `THIRD_PARTY_CRATES.txt` identiques, mais les deux `libmatrix_sdk_crypto_ffi.so` différents. Les chemins étaient déjà les mêmes sur les deux machines ; aucune reproduction locale (pas de NDK sur le poste, ADR-0009). `scripts/build.sh` fige désormais toutes les sources d'écart connues, sans rien retirer de la comparaison (octets de chaque fichier) :

- **Environnement vide** (`env -i` + liste explicite) : aucune variable propre à la machine (`GITHUB_*`, `RUNNER_*`, `ImageVersion`, `CI`) ne peut atteindre un `env!`/`option_env!` ou un script de compilation.
- **Chemins réécrits** : `--remap-path-prefix` (Rust) et `-ffile-prefix-map` (C de SQLite) pour le dossier de travail, `$CARGO_HOME`, `$RUSTUP_HOME` et le NDK, par variables `CARGO_TARGET_<cible>_RUSTFLAGS` et `CFLAGS_<cible>` (et non `RUSTFLAGS`, qui écraserait les options arm64 amont, recopiées et contrôlées inchangées).
- **Profil release figé** par `CARGO_PROFILE_RELEASE_*` : `codegen-units=1` (au lieu de 16), `strip=debuginfo` (UniFFI lit ses métadonnées dans la table des symboles pour générer le Kotlin : `strip=symbols` a fait échouer la 2e exécution), puis dépouillement des seules copies livrées (`out/jniLibs`) par le `llvm-strip --strip-all` du NDK épinglé, après la génération Kotlin (cargo-ndk 4.1.2 ne dépouille pas, contrairement à ce qu'indiquait ce README), `lto=false`, `debug=0`, `panic=unwind`, `incremental=false`, `CARGO_INCREMENTAL=0`.
- **Pas de note build-id** (`-Wl,--build-id=none`), `SOURCE_DATE_EPOCH` du commit amont, `TZ=UTC`, `LC_ALL=C.UTF-8`, `umask 0022`, droits des fichiers fixés, tris en collation C.
- **Diagnostic** joint à chaque artefact (`diag/`, hors archive publiée) : variables vues par la compilation, versions et empreintes des outils (clang, lld, bibliothèques standard Rust), empreinte de chaque section ELF. Si l'écart persiste, la tâche de comparaison affiche les sections différentes (`.text` ou `.rodata` : ordre de code produit par une macro ; `.comment` ou empreintes d'outils : image de machine différente) avant d'échouer.

Cause restante possible, non corrigeable par réglage : une macro procédurale d'une dépendance qui produit du code dans un ordre aléatoire (table de hachage). Le diagnostic par section la désignera ; il faudrait alors un correctif ciblé dans `patches/`.

## Points à vérifier à la première exécution

- Le correctif compile (attribut `#[uniffi(default = false)]` d'UniFFI 0.32 ; non compilé sur le poste).
- Les deux compilations sont identiques ; sinon, chercher la source d'écart (chemins, horodatages) avant toute publication.
- La liaison expose déjà la vérification SAS et QR (`start_sas_verification`, `generate_qr_code`, `scan_qr_code`) et la demande de secrets (`query_missing_secrets_from_other_sessions`) : lu dans les sources du tag. Les réglages `roomKeyRequestsEnabled` / `roomKeyForwardingEnabled` ne sont pas exposés, mais valent « vrai » par défaut dans matrix-sdk-crypto (comme sur le web), ce que M12 utilise.
- Durée et minutes consommées (dépôt public : exécuteurs standard gratuits).
