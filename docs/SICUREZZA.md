# Sicurezza

## Privilegi

Una sessione PPPoE costruita dal Mac richiede root per tre motivi:

- accesso BPF all'adattatore Ethernet;
- esecuzione di `pppd`, che crea `ppp0`;
- pubblicazione di route e DNS in `SCDynamicStore`.

- **Una richiesta per avvio.** All'avvio l'app chiede il diritto `system.privilege.admin` (password o Touch ID) e avvia **un solo** processo root, `ont-broker.sh`, tramite `AuthorizationExecuteWithPrivileges`. I comandi passano su una pipe privata che solo l'app possiede: altri processi non possono chiedere al broker di aprire sessioni.
- **Niente installato sul sistema.** Non ci sono LaunchDaemon, helper privilegiati o file in `/Library`. Chiusa l'app, il broker termina e ogni sessione si ferma da sola, perché il supervisore controlla che il processo dell'app esista ancora.
- **Comandi verificati.** Broker e supervisore controllano il formato di ogni argomento (interfaccia `^[a-z]+[0-9]+$`, VLAN numerica, cartella reale e non un collegamento simbolico, nessun apice nei percorsi) prima di costruire la riga di comando di `pppd`.
- **API deprecata, scelta consapevole.** `AuthorizationExecuteWithPrivileges` è deprecata, ma è l'unico modo di ottenere un processo root con una pipe privata senza installare un demone firmato con un certificato Developer ID (`SMAppService`).

### Limite noto

Gli script e il relay eseguiti come root stanno dentro il bundle dell'app, che appartiene all'utente. Un programma che gira già con l'account dell'utente potrebbe modificarli e ottenere root alla successiva autorizzazione. È lo stesso modello di fiducia di qualsiasi app che chiede la password di amministratore per eseguire componenti propri. Si risolverebbe con un helper `SMAppService` firmato e notarizzato, previsto quando il progetto avrà un certificato Developer ID.

## Credenziali

- Username e password stanno **solo in memoria** finché l'app è aperta. Non vengono salvati in UserDefaults né nel Portachiavi: a ogni avvio i campi sono vuoti.
- Per avviare `pppd` l'app scrive un file `secret` (`user` e `password`, quotati per `pppd`) con permessi **0600**, in una cartella di sessione **0700** dentro la cartella temporanea dell'utente. Il supervisore root lo **sposta** subito in `/var/run/ontthewire.XXXXXX`, leggibile solo da root, cancella l'originale e rimuove la copia alla fine della sessione.
- Le credenziali non compaiono nella riga di comando di `pppd` (sarebbero visibili con `ps`) e non vengono mai scritte nel log dell'app. `pppd` è avviato con `debug`, ma non registra le password CHAP né PAP.

### SIP Caller

- Numero, Auth ID e password SIP stanno **solo in memoria**, come le credenziali PPPoE.
- La password non viaggia in rete: il server riceve solo la risposta digest. Nella **Traccia SIP** anche la risposta digest è nascosta, così la traccia si può condividere.
- I **template 3CX** importati vengono salvati in `~/Library/Application Support/ONT The Wire/SIP templates`: contengono solo i dati pubblici del provider, mai credenziali.
- Il SIP Caller non usa privilegi di amministratore: gira con l'account dell'utente.

## Aggiornamenti automatici

- A ogni avvio l'app legge `https://api.github.com/repos/Abi0ne/ONT-the-Wire/releases/latest`. La richiesta non invia identificativi né dati dell'utente oltre a un `User-Agent` fisso.
- Una release valida contiene `ONT-The-Wire-<versione>.zip` e `ONT-The-Wire-<versione>.zip.sig`. Il `.sig` è una firma **Ed25519** dello zip, fatta con la chiave privata del progetto. La chiave pubblica è dentro l'app (`UpdateFeed.publicKey` in `Sources/ONTTheWireCore/Update/Updates.swift`).
- Prima dell'installazione l'app controlla che:
  1. la firma sia valida (altrimenti il pacchetto viene scartato);
  2. lo zip non superi 100 MB;
  3. il bundle estratto abbia lo stesso `CFBundleIdentifier` e la versione dichiarata dalla release;
  4. `codesign --verify --deep --strict` vada a buon fine.
- La sostituzione avviene dopo la chiusura dell'app, con un processo dell'utente e **senza privilegi**. Se lo scambio fallisce, viene ripristinata la versione precedente.
- La chiave privata **non** è nel repository. Vedi [BUILD.md](BUILD.md#chiave-di-firma).

## Rete

- Il test di velocità contatta solo Cloudflare (`speed.cloudflare.com`), Apple (`mensura.cdn-apple.com`) e OVH (`proof.ovh.net`), e solo quando lo avvii.
- Il SIP Caller contatta solo il server SIP indicato nel template o a mano, e solo quando premi **Registra**. Le chiamate di prova vanno ai numeri che scegli tu.
- L'app non invia telemetria.

## Segnalare un problema di sicurezza

Apri una [issue](https://github.com/Abi0ne/ONT-the-Wire/issues) senza dettagli sfruttabili e chiedi un contatto privato.
