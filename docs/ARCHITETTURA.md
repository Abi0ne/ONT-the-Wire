# Architettura

## Perché non il PPPoE di macOS

macOS ha un client PPPoE integrato e consente di crearlo sopra un'interfaccia VLAN (`vlan0`). Però il servizio salvato con `DeviceName = vlan0` in pratica non funziona: con `tcpdump` si vede che i PADI escono **senza tag 802.1Q** e con il MAC di `en0` (il Wi-Fi), perché il kernel usa sempre un'interfaccia fisica `en<N>`. Il PPPoE di sistema su VLAN quindi non raggiunge mai il concentratore.

ONT The Wire costruisce da sé i frame Ethernet, tag VLAN compreso, e gestisce da sé anche il protocollo PPP; gli indirizzi IPv4 passano da un'interfaccia `utun`.

### Perché non `pppd`

Fino alla 0.2.1 il PPP lo faceva `pppd` di sistema, con il relay come trasporto su un pty. Il pty di macOS passa i dati alla gestione PPP del kernel un byte alla volta (HDLC asincrono: escape e FCS-16 per ogni byte), in un solo flusso: sulla stessa linea in cui un router satura 1 Gbit/s ci si fermava a circa 320 Mbit/s in download e 340 in upload, con `pppoe-relay` vicino al 90% di un core e `kernel_task` oltre il 100% (misura del 4 novembre 2026). Con `utun` ogni pacchetto è una sola `read`/`write`, senza HDLC: nella prima prova il download ha superato i 900 Mbit/s.

## Componenti

```
┌───────────────────────── ONT The Wire.app (utente) ─────────────────────────┐
│ SwiftUI ── ConnectionController ── PrivilegedSession ── RootBroker ─────────┐│
│                 │                        ▲ legge relay.log / exit           ││
│                 └─ SpeedTest (NWConnection su utun<N>)                       ││
└──────────────────────────────────────────────────────────────────────────────┘│
        pipe privata (AuthorizationExecuteWithPrivileges)                        │
┌───────────────────────────── root ─────────────────────────────────────────────┘
│ ont-root-helper ─exec→ ont-broker.sh   (uno per avvio dell'app)
│                           │ START <dir> <iface> <vlan|-> <primary>
│                           ▼
│                     ont-session.sh     (uno per sessione, supervisore)
│                           │
│                           ▼
│      utun<N> ⇄ pppoe-relay -I en7 -V 835 -A <secret> ⇄ BPF ⇄ en7 ⇄ [802.1Q 835] ⇄ ONT ⇄ BRAS
└──────────────────────────────────────────────────────────────────────────────
```

### `pppoe-relay` (C, `Sources/pppoe-relay/main.c`)

Client PPPoE (RFC 2516) e PPP completo.

- Apre `/dev/bpf*` sull'interfaccia fisica con un filtro per gli EtherType 0x8863 (discovery) e 0x8864 (sessione). Con `-V` riconosce anche i frame con tag 802.1Q.
- **Discovery**: PADI → PADO → PADR → PADS. Il PADI viene ripetuto a intervalli fissi fino a `-T` secondi, il PADR fino a 3 volte.
- **LCP** (RFC 1661): chiede MRU 1492 e un magic number; accetta dal server MRU, magic e autenticazione PAP o CHAP-MD5 (a MS-CHAP o EAP risponde con un Nak che propone CHAP-MD5). Risponde agli LCP echo e ne manda uno ogni 10 s: dopo 4 senza risposta chiude la sessione. Ai protocolli che non gestisce (IPv6CP, CCP…) risponde con Protocol-Reject.
- **Autenticazione**: PAP (RFC 1334) o CHAP-MD5 (RFC 1994, anche le richieste ripetute durante la sessione). Credenziali dal file `-A`.
- **IPCP** (RFC 1332, 1877): chiede indirizzo e due DNS; li prende dal Nak del server.
- **Piano dati**: crea `utun<N>` (indirizzo punto-punto, MTU = min(1492, MRU del server)). I pacchetti sono divisi per connessione su più thread per direzione (vedi Prestazioni). Solo IPv4.
- Su SIGTERM/SIGHUP manda LCP Terminate-Request, poi **PADT**. Su PADT ricevuto esce subito.
- Scrive righe `STATUS …` nel suo log (`-L`), lette dall'app: `discovery`, `pado`, `session`, `timeout`, `error`, `padt`, `auth`, `auth-ok`, `auth-failed`, `interface`, `local`, `remote`, `dns`, `up` (tutto su una riga, per il supervisore), `echo-timeout`, `lcp-terminated`, `stats`.

Opzioni: `-I iface`, `-A credenziali`, `-V vlan`, `-P pcp`, `-S service`, `-C ac-name`, `-T timeout`, `-L logfile`, `-W thread` (thread del piano dati per direzione: 1, 2, 4 o 8; omesso, 4 con almeno 5 core ad alte prestazioni, 2 con almeno 3, altrimenti 1), `-G` (non unire i segmenti TCP ricevuti), `-D` (solo discovery, per diagnosi; non serve `-A`).

Codici di uscita, con gli stessi valori di `pppd` per gli stessi casi: 0 ok, 1 errore di sistema, 2 opzioni, 5 chiusura richiesta, 8 nessun PADO/PADS, 10 negoziazione PPP fallita, 15 il server non risponde agli echo, 16 sessione chiusa dal server (PADT, LCP Terminate), 19 autenticazione rifiutata.

**Prestazioni**:

- buffer BPF da 512 KB letto a blocchi;
- verso `utun` nessuna copia: i 4 byte prima dell'header IP nel buffer BPF vengono sovrascritti con l'intestazione di `utun` e il pacchetto parte con una sola `write`; in uscita il pacchetto viene letto subito dopo lo spazio per gli header Ethernet/VLAN/PPPoE/PPP;
- **più thread per direzione**, con QoS `USER_INTERACTIVE` per restare sui core ad alte prestazioni. Ogni pacchetto costa una chiamata di sistema per lato, e con un thread solo per direzione quel thread lavorava vicino al limite a 2 Gbit/s. Nella prova dell'11 novembre 2026 su una linea 2500/1000 i thread in più da soli non hanno cambiato le velocità (1,6–1,9 Gbit/s in download, 0,6–0,8 in upload): nessun thread del relay è più saturo e il limite è nel kernel (vedi l'unione dei segmenti). La somma delle porte TCP/UDP sceglie uno di N gruppi, lo stesso per i due sensi di una connessione, così i pacchetti di una connessione passano sempre dallo stesso thread e non cambiano ordine; frammenti e protocolli senza porte vanno nel gruppo 0.
  - *Ricezione*: N dispositivi BPF, ognuno con un filtro nel kernel che accetta solo l'IPv4 del suo gruppo e un thread che lo scrive su `utun`. Al thread principale restano discovery e controllo PPP.
  - *Invio*: un thread legge `utun` e passa ogni pacchetto alla coda del suo gruppo (512 pacchetti, un produttore e un consumatore); N thread scrivono le code ognuno sul proprio dispositivo BPF.
  - Con `-W 1`, o se i dispositivi BPF in più non si aprono, resta un thread per direzione come nella 0.3.0;
- **unione dei segmenti TCP ricevuti**. Il kernel elabora tutto ciò che arriva su `utun` in un solo thread (`dlil_input_utun<N>`), un pacchetto alla volta: in un campione di 20 s durante un test a 1,9 Gbit/s (11 novembre 2026, `spindump`) era il thread più carico del percorso, 12,5 s di CPU, mentre nessun thread del relay era saturo. I thread di ricezione uniscono quindi i segmenti consecutivi di una connessione arrivati nella stessa lettura BPF in un solo pacchetto IP fino a 64 KB, come il receive offload di una scheda di rete: il kernel elabora e conferma molti meno pacchetti. Si uniscono solo segmenti dati semplici (IPv4 senza opzioni né frammenti, solo ACK/PSH, stesse opzioni TCP a parte i timestamp, stesso TOS) con checksum IP e TCP validi; il checksum del pacchetto unito si ricava dalle somme già calcolate. Niente resta in attesa oltre la lettura, un PSH chiude subito il pacchetto e l'ordine dentro una connessione non cambia. Se `utun` rifiuta un pacchetto unito il relay consegna i segmenti originali e smette di unire; `-G` lo disattiva;
- se la coda dell'adattatore è piena (`ENOBUFS`) il frame in uscita viene ritentato fino a circa 10 ms invece di essere scartato, così il TCP rallenta per la coda di `utun` e non per una perdita;
- a fine sessione la riga `STATUS stats` riporta pacchetti per direzione, code piene, scarti, frame persi da BPF, errori delle interfacce e il carico massimo di ogni thread (quota di un core su circa un secondo): l'app la mostra nel Log. Un thread vicino al 100% è il punto in cui si perde velocità.

### `ont-root-helper` (C)

`AuthorizationExecuteWithPrivileges` avvia il processo con euid 0 ma uid reale dell'utente. L'helper esegue `setgid(0)`/`setuid(0)` e poi `exec` di `/bin/bash ont-broker.sh`, così broker, supervisore e relay girano come root a tutti gli effetti.

### `ont-broker.sh`

Uno per ogni avvio dell'app. Stampa `READY` e legge comandi dalla pipe privata con l'app:

| Comando | Risposta |
| --- | --- |
| `START <dir> <iface> <vlan\|-> <primary 0\|1>` | `STARTED` oppure `ERROR <messaggio>` |
| `PING` | `PONG` |

Quando l'app termina la pipe si chiude e il broker esce.

### `ont-session.sh`

Il supervisore di una singola sessione.

1. Controlla i parametri (formato dell'interfaccia, VLAN numerica, cartella non simbolica).
2. Sposta il file `secret` in `/var/run/ontthewire.XXXXXX`, leggibile solo da root, e cancella l'originale.
3. Avvia il relay:
   ```
   pppoe-relay -I <iface> -T 30 -L <dir>/relay.log -A <secret> [-V <vlan>]
   ```
4. Con "connessione principale", appena il relay scrive la riga `STATUS up`, pubblica in `SCDynamicStore` `State:/Network/Service/it.ontthewire.pppoe/IPv4` (con `OverridePrimary`) e `DNS`, che macOS usa per la route predefinita e i resolver. Li rimuove all'uscita.
5. Si ferma quando compare il file `<dir>/stop` o quando il processo dell'app non esiste più. Scrive il codice di uscita del relay in `<dir>/exit`.

### Lato Swift (`Sources/ONTTheWireCore`)

| File | Ruolo |
| --- | --- |
| `Session/RootBroker.swift` | Autorizzazione (`system.privilege.admin`), avvio dell'helper, protocollo sulla pipe |
| `Session/PrivilegedSession.swift` | Cartella di sessione (0700) e `secret` (0600), lettura dei log ogni 0,4 s, stop e timeout |
| `Session/SessionEvent.swift` | `SessionLogParser`: da righe di `relay.log` a eventi tipizzati |
| `Controller/ConnectionController.swift` | Macchina a stati, messaggi, watchdog di 75 s, codici di uscita del relay |
| `Network/InterfaceCatalog.swift` | Elenco degli adattatori e stato del link via `SCDynamicStore`, aggiornato a ogni collegamento o scollegamento |
| `SpeedTest/SpeedTest.swift` | Test di velocità multi-flusso |
| `Update/Updates.swift`, `Update/Updater.swift` | Aggiornamenti firmati da GitHub Releases |
| `SIP/SIPTemplate.swift`, `SIP/SIPTemplateStore.swift` | Lettura dei template 3CX (`gateway-template`, tipo `provider`) e copie importate |
| `SIP/SIPPhone.swift` | User agent SIP su UDP: registrazione, chiamate di prova, transazioni e dialoghi |
| `SIP/SIPMessage.swift`, `SIP/SIPDigest.swift`, `SIP/SDP.swift` | Messaggi SIP, autenticazione digest (MD5/SHA-256), SDP |
| `SIP/RTPStream.swift`, `SIP/G711.swift` | Audio RTP del test eco, codifica G.711 |
| `SIP/UDPSocket.swift` | Socket UDP legati a un'interfaccia (`IP_BOUND_IF`), elenco delle reti |

## Test di velocità

- Usa Network.framework: ogni `NWConnection` ha `requiredInterface` impostato sull'interfaccia della sessione (`utun<N>`), quindi il traffico passa dal PPPoE anche se non è la route predefinita.
- **Ping**: 10 handshake TCP verso `speed.cloudflare.com:443`; mediana e jitter (media delle differenze tra campioni consecutivi, come Ookla).
- **Download e upload**: 12 s ciascuno, i primi 2 s esclusi dalla media. I flussi vengono distribuiti tra i server rispettando il limite di ciascuno:

| Server | Download | Upload | Limite flussi |
| --- | --- | --- | --- |
| Cloudflare | `/__down?bytes=99000000` | `/__up` | — |
| Apple CDN (`mensura.cdn-apple.com`) | `/api/v1/gm/large` | `/api/v1/gm/slurp` | — |
| OVH (`proof.ovh.net`) | `/files/1Gb.dat` | — | 2 (oltre risponde HTTP 429) |

- Ogni flusso che finisce il proprio oggetto ne apre subito un altro. La latenza sotto carico viene campionata ogni 400 ms.

## SIP Caller

- **Template**: dal file 3CX si leggono `RegistrarHost/Port`, `ProxyHost/Port`, `TransportRestriction`, `IPRestriction`, `TimeBetweenRegistration`, la presenza di `3wayauthenticationid` (Auth ID distinto) e i codec. Le regole `ParameterIn/Out` e le altre opzioni di instradamento di 3CX non servono al test e vengono ignorate. Una copia del file va in `~/Library/Application Support/ONT The Wire/SIP templates`.
- **Trasporto**: solo UDP, con un socket BSD sulla porta 5060 (5062/5064 o una libera se occupata). Con una rete scelta il socket è legato all'interfaccia con `IP_BOUND_IF`; in automatico segue la route principale. Le richieste vanno sempre al server (proxy in uscita), le risposte all'indirizzo di provenienza della richiesta (RFC 3581).
- **Identificazione**: `User-Agent` (nelle richieste) e `Server` (nelle risposte) valgono `MANXX Validator <CFBundleShortVersionString>`.
- **Ritrasmissioni**: timer RFC 3261 (T1 500 ms raddoppiato, 4 s per le non-INVITE, timeout 32 s). Il 200 OK di una chiamata in entrata viene ritrasmesso fino all'ACK.
- **Autenticazione**: a un 401/407 la richiesta viene ripetuta una volta con `Authorization`/`Proxy-Authorization` digest (MD5, MD5-sess, SHA-256, qop `auth`).
- **NAT**: se `received`/`rport` del Via nel 200 OK del REGISTER differiscono dall'indirizzo locale, il Contact (e l'SDP) passa all'indirizzo pubblico e la registrazione viene ripetuta. Poi parte un keep-alive CRLF ogni 25 s. L'RTP è simmetrico: l'audio va all'indirizzo da cui arrivano i pacchetti.
- **Audio**: G.711 A-law o µ-law (`telephone-event` offerto), 20 ms per pacchetto. Due toni a 1 kHz, poi eco dei pacchetti ricevuti (al massimo 0,5 s in coda). Si contano i pacchetti e il picco in dBFS.
- **Limiti**: niente TCP/TLS, SRTP, G.729, STUN o IPv6; la chiamata di prova dura al massimo 60 s.

## Stati della connessione

```
idle → preparing → searchingServer → authenticating → configuringNetwork → connected
                         │                  │                   │               │
                         └──────────────────┴───────── failed ◀─┴───────────────┘
connected → disconnecting → idle
```

`failed` mostra il motivo, ricavato dagli eventi di sessione oppure dal codice di uscita del relay:

| Codice | Significato |
| --- | --- |
| 19 | Autenticazione |
| 8 | Nessun server PPPoE |
| 15 | Il server non risponde più |
| 16 | Linea caduta |
| 2 | Opzioni |
| 10 | LCP |
