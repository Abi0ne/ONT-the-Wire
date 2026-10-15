# Compilazione e rilascio

## Requisiti

- macOS 14 o successivo, Apple Silicon.
- Swift 6: bastano i **Command Line Tools** (`xcode-select --install`), Xcode non serve.

Con i soli Command Line Tools alcune macro non sono disponibili:

- nelle viste si usa `@AppStorage` oppure modelli `@Observable` al posto di `@State`;
- i test passano da `scripts/test.sh`, che indica a SwiftPM dove si trova il plugin di swift-testing.

## Struttura

```
Package.swift
Sources/
  ONTTheWire/          app SwiftUI (viste)
  ONTTheWireCore/      logica: sessione, controller, test di velocità, aggiornamenti
  pppoe-relay/         trasporto PPPoE in C (BPF + 802.1Q)
  ont-root-helper/     helper C che diventa root ed esegue il broker
Resources/
  Info.plist           versione dell'app (CFBundleShortVersionString)
  AppIcon.icns         generata da scripts/make-icon.swift
  ont-broker.sh        broker root (uno per avvio)
  ont-session.sh       supervisore root (uno per sessione)
Tests/ONTTheWireCoreTests/
scripts/
  build-app.sh         crea build/ONT The Wire.app
  test.sh              test unitari
  make-icon.swift      disegna l'icona
  make-dmg.sh          immagine disco per l'installazione manuale
  make-release.sh      zip firmato + dmg in build/release/
  update-signing.swift chiavi e firme Ed25519
```

## Compilare ed eseguire

```sh
./scripts/build-app.sh                 # release; "./scripts/build-app.sh debug" per il debug
open "build/ONT The Wire.app"
./scripts/test.sh
```

`build-app.sh` compila i tre prodotti, assembla il bundle (gli eseguibili root vanno in `Contents/Resources`) e lo firma ad hoc con hardened runtime.

L'icona si rigenera con:

```sh
swift scripts/make-icon.swift [cartella-per-anteprima-png]
```

## Chiave di firma

Gli aggiornamenti automatici installano solo zip firmati con la chiave Ed25519 del progetto (vedi [SICUREZZA.md](SICUREZZA.md#aggiornamenti-automatici)).

- **Chiave privata**: `~/.config/ontthewire/update-ed25519.key` (permessi 0600). **Non va mai inserita nel repository.** Conservane una copia di sicurezza: se va persa, le app già installate non accetteranno più aggiornamenti, e servirà un'installazione manuale di una versione con una nuova chiave pubblica.
- **Chiave pubblica**: `UpdateFeed.publicKey` in `Sources/ONTTheWireCore/Update/Updates.swift`.

```sh
swift scripts/update-signing.swift genkey <file>          # nuova chiave, stampa la pubblica
swift scripts/update-signing.swift public <file>          # stampa la pubblica
swift scripts/update-signing.swift sign <file> <zip>      # stampa la firma
swift scripts/update-signing.swift verify <pubblica> <zip> <firma>
```

## Pubblicare una release

1. Aggiorna `CFBundleShortVersionString` (e `CFBundleVersion`) in `Resources/Info.plist`.
2. Aggiungi la voce in `CHANGELOG.md`.
3. Esegui `./scripts/test.sh`.
4. Esegui `./scripts/make-release.sh`. Lo script:
   - controlla che la chiave privata corrisponda a quella pubblica nell'app;
   - compila l'app;
   - crea in `build/release/` i file `ONT-The-Wire-<v>.zip`, `.zip.sig` e `.dmg`;
   - verifica la firma.
5. Fai commit, crea il tag e pubblica la release:
   ```sh
   git commit -am "Versione X.Y.Z" && git tag vX.Y.Z && git push --follow-tags
   gh release create vX.Y.Z --repo Abi0ne/ONT-the-Wire --title "ONT The Wire X.Y.Z" \
       --notes-file note.md build/release/*
   ```

Il tag deve essere `v` seguito dalla versione di `Info.plist`, e il nome dello zip deve corrispondere: l'app li confronta prima di installare. Le pre-release e le bozze vengono ignorate dall'aggiornamento automatico.
