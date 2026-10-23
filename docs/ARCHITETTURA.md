# Architettura

## Perché non il PPPoE di macOS

macOS ha un client PPPoE integrato e consente di crearlo sopra un'interfaccia VLAN (`vlan0`). Però il servizio salvato con `DeviceName = vlan0` in pratica non funziona: con `tcpdump` si vede che i PADI escono **senza tag 802.1Q** e con il MAC di `en0` (il Wi-Fi), perché il kernel usa sempre un'interfaccia fisica `en<N>`. Il PPPoE di sistema su VLAN quindi non raggiunge mai il concentratore.

ONT The Wire costruisce da sé i frame Ethernet, tag VLAN compreso, e affida a `pppd` di sistema solo il protocollo PPP.

## Componenti

```
┌───────────────────────── ONT The Wire.app (utente) ─────────────────────────┐
│ SwiftUI ── ConnectionController ── PrivilegedSession ── RootBroker ─────────┐│
│                 │                        ▲ legge relay.log / pppd.log / exit ││
│                 └─ SpeedTest (NWConnection su ppp0)                          ││
└──────────────────────────────────────────────────────────────────────────────┘│
        pipe privata (AuthorizationExecuteWithPrivileges)                        │
┌───────────────────────────── root ─────────────────────────────────────────────┘
│ ont-root-helper ─exec→ ont-broker.sh   (uno per avvio dell'app)
│                           │ START <dir> <iface> <vlan|-> <primary>
│                           ▼
│                     ont-session.sh     (uno per sessione, supervisore)
│                           │
│                           ▼
│              /usr/sbin/pppd  pty "pppoe-relay -I en7 -V 835"
│                           │  HDLC asincrono su pty
│                           ▼
│                     pppoe-relay ── BPF ── en7 ── [802.1Q 835] ── ONT ── BRAS
└──────────────────────────────────────────────────────────────────────────────
```

### `pppoe-relay` (C, `Sources/pppoe-relay/main.c`)

Il trasporto PPPoE (RFC 2516) per `pppd`.

- Apre `/dev/bpf*` sull'interfaccia fisica con un filtro per gli EtherType 0x8863 (discovery) e 0x8864 (sessione). Con `-V` riconosce anche i frame con tag 802.1Q.
- **Discovery**: PADI → PADO → PADR → PADS. Il PADI viene ripetuto a intervalli fissi fino a `-T` secondi, il PADR fino a 3 volte.
- **Sessione**: verso `pppd` parla HDLC asincrono sul pty (flag 0x7E, escape 0x7D, FCS-16), verso la rete frame PPPoE di sessione con il tag VLAN e la priorità PCP (`-P`) aggiunti dal relay.
- Su SIGTERM/SIGHUP, o alla chiusura del pty, invia **PADT** al concentratore. Su PADT ricevuto esce con codice 4.
- Scrive righe `STATUS …` nel suo log (`-L`), lette dall'app: `discovery`, `pado`, `session`, `timeout`, `error`, `padt`.

Opzioni: `-I iface`, `-V vlan`, `-P pcp`, `-S service`, `-C ac-name`, `-T timeout`, `-L logfile`, `-D` (solo discovery, per diagnosi).

Codici di uscita: 0 ok, 1 errore di sistema, 2 nessun PADO, 3 nessun PADS, 4 PADT ricevuto.

**Prestazioni**: con una sessione da gigabit il relay è sul percorso di ogni pacchetto. Per questo:

- usa un buffer BPF da 512 KB;
- raccoglie tutti i frame di una lettura BPF in un buffer da 1 MB e li scrive verso `pppd` in una sola `write`;
- calcola escape e FCS con tabelle in un solo passaggio;
- nel decoder copia a blocchi i tratti che non hanno escape.

### `ont-root-helper` (C)

`AuthorizationExecuteWithPrivileges` avvia il processo con euid 0 ma uid reale dell'utente. L'helper esegue `setgid(0)`/`setuid(0)` e poi `exec` di `/bin/bash ont-broker.sh`, così broker, supervisore e `pppd` girano come root a tutti gli effetti.

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
3. Avvia `pppd` con queste opzioni:
   ```
   pty "'<relay>' -I <iface> -T 30 -L '<dir>/relay.log' [-V <vlan>]"
   file <secret> nodetach debug logfile <dir>/pppd.log
   noauth noipdefault usepeerdns mtu 1492 mru 1492
   noaccomp nopcomp novj noccp
   lcp-echo-interval 10 lcp-echo-failure 4 maxfail 1
   ```
4. Con "connessione principale" pubblica in `SCDynamicStore` `State:/Network/Service/it.ontthewire.pppoe/IPv4` (con `OverridePrimary`) e `DNS`, che macOS usa per la route predefinita e i resolver. Li rimuove all'uscita.
5. Si ferma quando compare il file `<dir>/stop` o quando il processo dell'app non esiste più. Scrive il codice di uscita di `pppd` in `<dir>/exit`.

### Lato Swift (`Sources/ONTTheWireCore`)

| File | Ruolo |
| --- | --- |
| `Session/RootBroker.swift` | Autorizzazione (`system.privilege.admin`), avvio dell'helper, protocollo sulla pipe |
| `Session/PrivilegedSession.swift` | Cartella di sessione (0700) e `secret` (0600), lettura dei log ogni 0,4 s, stop e timeout |
| `Session/SessionEvent.swift` | `SessionLogParser`: da righe di `relay.log` e `pppd.log` a eventi tipizzati |
| `Controller/ConnectionController.swift` | Macchina a stati, messaggi, watchdog di 75 s, codici di uscita di `pppd` |
| `Network/InterfaceCatalog.swift` | Elenco degli adattatori e stato del link via `SCDynamicStore`, aggiornato a ogni collegamento o scollegamento |
| `SpeedTest/SpeedTest.swift` | Test di velocità multi-flusso |
| `Update/Updates.swift`, `Update/Updater.swift` | Aggiornamenti firmati da GitHub Releases |
| `SIP/SIPTemplate.swift`, `SIP/SIPTemplateStore.swift` | Lettura dei template 3CX (`gateway-template`, tipo `provider`) e copie importate |
| `SIP/SIPPhone.swift` | User agent SIP su UDP: registrazione, chiamate di prova, transazioni e dialoghi |
| `SIP/SIPMessage.swift`, `SIP/SIPDigest.swift`, `SIP/SDP.swift` | Messaggi SIP, autenticazione digest (MD5/SHA-256), SDP |
| `SIP/RTPStream.swift`, `SIP/G711.swift` | Audio RTP del test eco, codifica G.711 |
| `SIP/UDPSocket.swift` | Socket UDP legati a un'interfaccia (`IP_BOUND_IF`), elenco delle reti |

## Test di velocità

- Usa Network.framework: ogni `NWConnection` ha `requiredInterface` impostato sull'interfaccia `ppp0`, quindi il traffico passa dal PPPoE anche se non è la route predefinita.
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

`failed` mostra il motivo, ricavato dagli eventi di sessione oppure dal codice di uscita di `pppd`:

| Codice | Significato |
| --- | --- |
| 19 | Autenticazione |
| 8 | Nessun server PPPoE |
| 15 | Il server non risponde più |
| 16 | Linea caduta |
| 2 | Opzioni |
| 10 | LCP |
