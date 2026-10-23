# Manuale d'uso di ONT The Wire

Versione 0.2.1

## Indice

1. [A cosa serve](#1-a-cosa-serve)
2. [Cosa serve](#2-cosa-serve)
3. [Installazione](#3-installazione)
4. [Primo avvio e autorizzazione](#4-primo-avvio-e-autorizzazione)
5. [Collegamento fisico](#5-collegamento-fisico)
6. [Configurazione](#6-configurazione)
7. [Connessione](#7-connessione)
8. [Riepilogo della sessione](#8-riepilogo-della-sessione)
9. [Test di velocità](#9-test-di-velocità)
10. [Log](#10-log)
11. [Disconnessione e chiusura](#11-disconnessione-e-chiusura)
12. [SIP Caller](#12-sip-caller)
13. [Aggiornamenti](#13-aggiornamenti)
14. [Messaggi di errore e soluzioni](#14-messaggi-di-errore-e-soluzioni)
15. [Verifiche da Terminale](#15-verifiche-da-terminale)
16. [Domande frequenti](#16-domande-frequenti)

## 1. A cosa serve

ONT The Wire trasforma il Mac nel router di una linea FTTH. Colleghi il Mac alla porta LAN dell'ONT e l'app apre la sessione PPPoE con le credenziali dell'operatore, aggiungendo il tag VLAN 802.1Q richiesto (ad esempio 835 per TIM). Servono a:

- verificare che la linea autentichi e riceva un indirizzo IP, senza router del cliente;
- vedere quale concentratore (BRAS) risponde e con quale Session ID;
- misurare la velocità reale della linea con un test multi-flusso;
- raccogliere un log completo della negoziazione da allegare a una segnalazione;
- verificare una linea VoIP: registrazione SIP e chiamate di prova in uscita e in entrata (sezione **SIP Caller**).

## 2. Cosa serve

- Un Mac con Apple Silicon e **macOS 14 Sonoma** o successivo.
- Un **account amministratore** sul Mac. L'app deve accedere direttamente alla scheda di rete.
- Un **adattatore Ethernet** USB-C o Thunderbolt. Va bene qualsiasi modello riconosciuto da macOS e non è legato a un modello specifico: l'app elenca quelli collegati in quel momento.
- Un cavo di rete.
- Dall'operatore: **VLAN ID** (se previsto), **username** e **password** PPPoE.

> Per un test di velocità attendibile su linee da 1 Gbit/s o più, usa un adattatore da almeno 2,5 Gbit/s, oppure uno da 1 Gbit/s sapendo che sarà quello il limite.

## 3. Installazione

1. Scarica `ONT-The-Wire-0.2.1.dmg` da [GitHub Releases](https://github.com/Abi0ne/ONT-the-Wire/releases/latest).
2. Apri il DMG e trascina **ONT The Wire** sulla cartella **Applicazioni**.
3. Apri l'app da Applicazioni.

### L'app non si apre al primo avvio

L'app non è notarizzata da Apple, quindi macOS la blocca la prima volta con un messaggio come "Apple non può verificare che ONT The Wire non contenga malware". Si sblocca una volta sola.

- **macOS 15 e successivi**:
  1. Premi **Fine** sull'avviso.
  2. Apri **Impostazioni di Sistema › Privacy e sicurezza**.
  3. Nella sezione **Sicurezza** premi **Apri comunque** e conferma.
- **macOS 14**: nel Finder fai clic destro sull'app, scegli **Apri** e conferma.
- **Da Terminale**:
  ```sh
  xattr -dr com.apple.quarantine "/Applications/ONT The Wire.app"
  ```

> Tieni l'app in **Applicazioni** o in un'altra cartella in cui puoi scrivere. Se la lanci direttamente dal DMG o da Download, macOS potrebbe eseguirla da una posizione temporanea e l'aggiornamento automatico non riesce a sostituirla.

## 4. Primo avvio e autorizzazione

All'avvio macOS chiede la **password di amministratore**, o Touch ID se il sistema lo consente. È l'unica richiesta: l'autorizzazione vale per tutte le connessioni e disconnessioni finché l'app resta aperta. Alla chiusura dell'app termina anche il processo con privilegi.

Se annulli la richiesta l'app resta utilizzabile e l'autorizzazione verrà chiesta alla prima pressione di **Connetti**.

> L'autorizzazione serve per tre cose: leggere e scrivere frame Ethernet direttamente sull'adattatore (BPF), avviare `pppd` e, se scegli "connessione principale", cambiare route e DNS. Vedi [SICUREZZA.md](SICUREZZA.md).

## 5. Collegamento fisico

1. Collega l'adattatore Ethernet al Mac.
2. Collega il cavo dalla **porta LAN dell'ONT** (spesso "LAN1" o "GE1") all'adattatore.
3. Accendi l'ONT e aspetta che il LED **PON** o fibra sia acceso fisso. Se il LED **LOS** è rosso, la fibra non arriva e il PPPoE non può funzionare.

L'app si accorge da sola quando colleghi o scolleghi un adattatore. Se l'elenco non si aggiorna, premi ⟳ accanto a "Adattatore Ethernet".

## 6. Configurazione

La finestra ha due colonne: a sinistra la configurazione, a destra stato, comandi, riepilogo e log.

| Campo | Cosa inserire |
| --- | --- |
| **Adattatore** | L'adattatore collegato all'ONT, ad esempio "USB 10/100/1G/2.5G LAN (en7)". Sotto compare **Link**: deve essere *Attivo* (verde). |
| **VLAN ID** | Il tag 802.1Q dell'operatore, da 1 a 4094. TIM usa **835**. **Vuoto** significa frame senza tag, per gli operatori o le ONT che non lo richiedono. |
| **Username / Password** | Le credenziali PPPoE della linea. |
| **Usa come connessione principale** | Se attivo, a sessione connessa route predefinita e DNS del Mac passano dal PPPoE anche con il Wi-Fi acceso. Se è spento il PPPoE si attiva ma il traffico del Mac continua a uscire dalla rete abituale, e il test di velocità usa comunque il PPPoE. |

> **Nessun dato viene salvato.** A ogni avvio tutti i campi sono vuoti. Le credenziali restano in memoria solo finché l'app è aperta e non vengono scritte nel Portachiavi, nelle preferenze o nel log.

Se manca qualcosa, sotto i pulsanti compare l'elenco **"Per connetterti manca:"**.

## 7. Connessione

Premi **Connetti** (o ⏎). Lo stato passa per queste fasi:

| Stato | Cosa succede |
| --- | --- |
| **Avvio** | Preparazione della sessione |
| **Ricerca del server PPPoE** | PADI inviati con il tag VLAN e attesa del PADO dal concentratore (al massimo 30 s) |
| **Autenticazione** | Sessione PPPoE aperta, negoziazione LCP e invio delle credenziali (CHAP o PAP) |
| **Configurazione indirizzo IP** | IPCP: il server assegna indirizzo, gateway e DNS |
| **Connessa** | Sessione attiva: compare l'interfaccia `ppp0` con il suo indirizzo |

Se dopo **75 secondi** la connessione non è completa, il tentativo viene interrotto e l'app mostra il motivo.

Mentre la sessione è attiva i campi di configurazione sono bloccati. Il collegamento viene controllato con LCP echo ogni 10 s e, dopo 4 risposte mancate, la sessione si considera caduta.

## 8. Riepilogo della sessione

La scheda **Riepilogo** mostra:

- **Adattatore** e **Link**;
- **VLAN** (oppure "senza tag");
- **Concentratore**: nome (AC-Name) e MAC del BRAS che ha risposto. Utile per capire su quale apparato è attestata la linea;
- **Sessione PPPoE**: il Session ID;
- **Interfaccia PPP**, **Indirizzo**, **Gateway** e **DNS** assegnati;
- **Connessione principale**: sì o no.

Tutti i valori si possono selezionare e copiare.

## 9. Test di velocità

Si trova sotto il riepilogo ed è disponibile solo a sessione **connessa**. Il traffico esce sempre dall'interfaccia PPP, anche se "connessione principale" è spenta.

1. Scegli il numero di **flussi paralleli**: **8** (predefinito), **16** o **32**.
2. Premi **Avvia**. Puoi fermarlo in qualunque momento con **Interrompi**.

Le fasi:

| Fase | Come viene misurata |
| --- | --- |
| **Ping / jitter** | 10 handshake TCP verso Cloudflare: mediana e variazione media tra campioni consecutivi |
| **Download** | 12 s con tutti i flussi aperti in parallelo verso Cloudflare, Apple CDN e OVH. I primi 2 s di avvio sono esclusi dalla media |
| **Upload** | 12 s verso Cloudflare e Apple CDN, con lo stesso metodo |
| **Latenza sotto carico** | Ping misurato durante download e upload, per capire se la linea "si siede" (bufferbloat) |

Il risultato riporta anche la **ripartizione per server** (ad esempio `Cloudflare 48% · Apple CDN 41% · OVH 11%`) ed eventuali **avvisi**, come un server che non ha risposto. Il risultato viene scritto anche nel log.

**Come scegliere i flussi**: con un solo flusso TCP non si satura una linea FTTH veloce. Parti da 8. Se il risultato è sotto il profilo commerciale, riprova con 16 e poi con 32: se sale, il limite era il numero di connessioni e non la linea.

## 10. Log

La scheda **Log** riporta, con orario, tutto quello che fa la sessione:

- discovery PPPoE (PADI, PADO con nome e MAC del concentratore, PADR, PADS con Session ID, PADT);
- fasi PPP (LCP, autenticazione, IPCP) e indirizzi ottenuti;
- messaggi di errore di pppd tradotti;
- risultati del test di velocità e degli aggiornamenti.

Da qui puoi copiare tutto il log per allegarlo a una segnalazione. Le credenziali non compaiono mai nel log.

## 11. Disconnessione e chiusura

- **Disconnetti** chiude la sessione PPPoE (con PADT al concentratore) e ripristina route e DNS se l'app li aveva cambiati.
- **Chiudendo l'app** con una sessione attiva, l'app disconnette prima di uscire.
- Se l'app si chiude in modo anomalo, il supervisore della sessione se ne accorge e chiude tutto da solo: nessuna configurazione resta appesa sul Mac.

## 12. SIP Caller

La sezione **SIP Caller** (in alto nella barra della finestra, accanto a **Connessione PPPoE**) verifica che un numero VoIP funzioni davvero: si registra sul server SIP del provider, chiama un numero e risponde a una chiamata, controllando l'audio in entrambe le direzioni. È sempre disponibile e non richiede la sessione PPPoE.

### Template 3CX

I dati del server si importano da un **template di provider SIP trunk esportato da 3CX** (file `.xml`, tipo `gateway-template`):

1. premi il pulsante di importazione (freccia in giù) accanto a **Template 3CX** e scegli uno o più file;
2. il provider compare nel menu **Provider**: sceglilo per compilare **Server SIP** e **Porta**. A ogni avvio il menu parte da **Seleziona…** e tutti i campi sono vuoti.

I template restano disponibili ai successivi avvii, perché non contengono credenziali. Il cestino rimuove il template selezionato. Senza template lascia **Seleziona…** e compila server e porta a mano.

Sotto il menu compaiono i parametri del provider: registrar e porta, eventuale proxy, trasporto, intervallo di registrazione e codec.

### Account

- **Numero / ID**: il numero della linea (utente SIP).
- **Auth ID**: l'utente per l'autenticazione, se diverso dal numero. Vuoto: si usa il numero. Se il template lo prevede (3-way authentication di 3CX), sotto i campi compare un promemoria.
- **Password**: la password SIP.
- **Server SIP** e **Porta**: compilati dal template, modificabili.

Come per il PPPoE, le credenziali **non vengono salvate**.

### Rete

Il test funziona su qualsiasi connessione del Mac:

- **Automatica**: la rete principale del Mac (se il PPPoE è la connessione principale, passa da lì);
- una rete precisa: **PPPoE** (`ppp0`, quando la sessione di ONT The Wire è attiva), **Wi‑Fi**, **Ethernet**…

Dietro un router (Wi‑Fi o cavo di casa), l'app ricava l'indirizzo pubblico dalla risposta del server, si registra di nuovo con quell'indirizzo e tiene aperta la porta sul router con un messaggio ogni 25 s. Il PPPoE di solito ha un indirizzo pubblico e non ne ha bisogno.

### Registrazione

Premi **Registra**. Lo stato in alto diventa **Registrato** con la rete usata e l'intervallo di rinnovo; l'app rinnova la registrazione da sola. Sul server l'app compare come **MANXX Validator** seguito dalla versione (ad esempio `MANXX Validator 0.2.0`): è il nome che vedi nei pannelli del provider che mostrano il dispositivo registrato, come l'advisor di WiC. **Deregistra** cancella la registrazione dal server (anche alla chiusura dell'app).

### Chiamata in uscita

Scrivi il numero da chiamare (ad esempio il tuo cellulare) e premi **Chiama**. Quando rispondi senti **due toni** e poi **la tua voce in eco**: se ti senti, l'audio passa in entrambe le direzioni. La chiamata si chiude da sola dopo 60 secondi, oppure con **Riaggancia**. Se nessuno risponde entro 60 secondi la chiamata viene annullata.

### Chiamata in entrata

Premi **Attendi chiamata** e chiama il numero della linea da un altro telefono. L'app risponde dopo circa due secondi con lo stesso test eco. L'attesa dura al massimo 3 minuti.

### Esito

Al termine di ogni prova il riquadro **Esito** mostra direzione, risposta, durata, codec (G.711 A-law o µ-law), pacchetti audio RTP inviati e ricevuti, livello di picco ricevuto e indirizzo remoto dell'audio. Se la chiamata è stata risposta ma **nessun pacchetto audio** è arrivato, l'esito lo segnala: di solito è un firewall o un NAT che blocca l'RTP.

La scheda **Test** (quella iniziale) contiene le chiamate di prova e l'esito; **Log** riassume le prove; **Traccia SIP** mostra i messaggi SIP completi (copiabili), con le risposte digest nascoste.

### Messaggi del SIP Caller

| Messaggio | Causa probabile | Cosa fare |
| --- | --- | --- |
| **Il server SIP … non risponde** | Server o porta sbagliati, oppure la rete blocca UDP 5060 | Controlla server e porta; prova un'altra rete (ad esempio il PPPoE) |
| **Credenziali rifiutate (401/407)** | Auth ID o password errati | Ricontrolla Auth ID (spesso diverso dal numero) e password |
| **Registrazione rifiutata (403)** | Credenziali errate o registrazione ammessa solo da certi indirizzi IP | Verifica con il provider; prova dalla linea del cliente (PPPoE) |
| **Account sconosciuto al server (404)** | Numero / ID errato | Ricontrolla il numero |
| **Chiamata non autorizzata (403)** | Chiamate uscenti non abilitate o numero non consentito | Verifica il profilo della linea |
| **Codec non accettato dal provider (488)** | Il provider vuole solo G.729 | L'app usa G.711: chiedi al provider di abilitarlo |
| **Nessun audio ricevuto dall'altra parte** | RTP bloccato da firewall o NAT | Prova sul PPPoE o disattiva il SIP ALG del router |

Il firewall di macOS, se attivo, al primo uso può chiedere di consentire le connessioni in entrata a ONT The Wire: consentile, altrimenti le chiamate in entrata non arrivano.

## 13. Aggiornamenti

A ogni avvio l'app controlla su GitHub se esiste una versione più recente. Se c'è:

1. la scarica in background;
2. verifica la **firma Ed25519** del pacchetto e scarta qualsiasi pacchetto non firmato con la chiave del progetto;
3. mostra l'avviso **"ONT The Wire X.Y.Z è pronta"**, con tre scelte:
   - **Riavvia e installa**: chiude la sessione PPPoE se è attiva, sostituisce l'app e la riapre;
   - **Novità**: apre le note della release;
   - **Alla chiusura**: l'aggiornamento verrà installato quando esci dall'app.

Puoi controllare anche a mano dal menu **ONT The Wire › Controlla aggiornamenti…**.

Se sei senza Internet (ad esempio in campo con il solo ONT collegato), il controllo non va a buon fine senza disturbare. Rimane solo una riga nel log.

## 14. Messaggi di errore e soluzioni

| Messaggio | Causa probabile | Cosa fare |
| --- | --- | --- |
| **Il collegamento Ethernet non è attivo** | Cavo staccato, ONT spento o porta LAN sbagliata | Controlla il cavo e i LED dell'ONT. Prova un'altra porta LAN |
| **Nessun server PPPoE ha risposto: verifica VLAN ID, cavo e ONT** | Nessun PADO entro 30 s | Verifica il VLAN ID (TIM: 835; altri operatori possono non usare tag: prova a lasciarlo vuoto). Controlla che la fibra sia agganciata (LED PON fisso, LOS spento) e che la linea sia attiva |
| **Autenticazione rifiutata: controlla username e password** | Il BRAS ha rifiutato CHAP o PAP | Ricontrolla le credenziali: maiuscole, minuscole e dominio, ad esempio `@alice.it`. Su alcune linee l'operatore deve ancora attivare il profilo |
| **Negoziazione PPP non riuscita: il server non risponde alle richieste LCP** | Sessione PPPoE aperta ma LCP senza risposta | Riprova; se si ripete, la linea ha un problema lato operatore |
| **Il server PPPoE ha smesso di rispondere** | LCP echo senza risposta per circa 40 s | Instabilità della linea o del BRAS |
| **Il server ha chiuso il collegamento** | PADT o LCP Terminate dal concentratore | Spesso è una sessione duplicata o una chiusura lato operatore. Attendi un minuto e riconnetti |
| **Collegamento Ethernet perso** | Cavo o adattatore scollegato, oppure ONT riavviato durante la sessione | Ricollega e riconnetti |
| **Connessione non stabilita entro 75 secondi** | La negoziazione è rimasta bloccata in una fase | Leggi il log per vedere in quale fase |
| **Autorizzazione annullata** | Hai premuto Annulla sulla richiesta di password | Premi di nuovo **Connetti** e autorizza |
| **L'adattatore selezionato non è più presente** | L'adattatore è stato scollegato | Ricollegalo o scegline un altro |

### Il test di velocità dà valori bassi

- Prova con **32 flussi**.
- Verifica la velocità dell'adattatore: un modello USB da 1 Gbit/s non supera circa 940 Mbit/s.
- Chiudi applicazioni che usano la rete, come backup iCloud o sincronizzazioni.
- Controlla la **latenza sotto carico**: se sale di centinaia di ms, la linea o la rete dell'operatore è congestionata.
- Guarda gli **avvisi** del test: se un server non ha risposto, il totale è stato raccolto dagli altri.

## 15. Verifiche da Terminale

A sessione connessa:

```sh
ifconfig ppp0                          # indirizzo della sessione
route -n get default                   # con "connessione principale": interface ppp0
ping -c 3 -b ppp0 1.1.1.1              # ping forzato sull'interfaccia PPPoE
scutil --dns | grep -A3 ppp0           # DNS forniti dall'operatore
```

Dopo la disconnessione non deve rimanere nulla:

```sh
pgrep -l pppd; pgrep -l pppoe-relay    # nessun processo
route -n get default                   # di nuovo l'interfaccia abituale
```

## 16. Domande frequenti

**Devo creare la VLAN in Impostazioni di Sistema?**
No. L'app costruisce da sola i frame con il tag 802.1Q e non cambia la configurazione di rete di macOS.

**Funziona con qualsiasi adattatore Ethernet?**
Sì, con qualsiasi adattatore che macOS veda come interfaccia `en`. Ogni volta si sceglie quello collegato in quel momento.

**Posso tenere il Wi-Fi acceso?**
Sì. Con "connessione principale" spenta il Mac continua a usare il Wi-Fi e il PPPoE serve solo per le verifiche e il test di velocità. Con l'opzione accesa tutto il traffico passa dal PPPoE.

**Perché mi chiede la password a ogni avvio?**
L'autorizzazione non viene conservata tra un avvio e l'altro, per scelta: nessun componente con privilegi resta installato sul Mac quando l'app è chiusa.

**IPv6?**
Non ancora: la versione 0.1.0 negozia solo IPv4 (IPCP).

**Dove trovo i log tecnici di pppd?**
Durante la sessione stanno in una cartella temporanea privata e vengono riportati nella scheda Log. Alla chiusura vengono cancellati.
