# Novità

## 0.3.1 — 11 novembre 2026

- **PPPoE su più core**: il traffico della sessione è diviso per connessione su più thread per direzione (4 sui Mac con almeno 5 core ad alte prestazioni), così nessun thread dell'app fa da collo di bottiglia sulle linee a 2,5 Gbit/s.
- **Download più leggero per il sistema**: i segmenti TCP ricevuti vengono uniti in pacchetti grandi prima di passarli a macOS, che su `utun` li elabora uno alla volta in un solo thread: era quello il punto più carico del percorso. Su una linea 2500/1000 il download con 8 flussi è passato da circa 1,6 a 2,0 Gbit/s (nella stessa prova è cambiato anche l'adattatore Ethernet).
- Le statistiche a fine sessione nel Log riportano anche il carico massimo di ogni thread e quanti segmenti sono stati uniti.

## 0.3.0 — 9 novembre 2026

- **PPPoE molto più veloce**: l'app gestisce da sé il protocollo PPP (LCP, PAP/CHAP, IPCP) e porta il traffico su un'interfaccia `utun`, senza più `pppd`. Prima il passaggio dei dati attraverso un pty limitava la sessione a circa 350 Mbit/s; ora il download supera i 900 Mbit/s su una linea da 1 Gbit/s.
- Nel riepilogo l'interfaccia della sessione è `utun<N>` invece di `ppp0`.
- A fine sessione il Log riporta le statistiche dei pacchetti (inviati, ricevuti, code piene, scarti), utili per capire dove si perde velocità.

## 0.2.1 — 23 ottobre 2026

- All'avvio l'app si apre sempre sulla sezione **Connessione PPPoE**.
- **SIP Caller**: nessun template preselezionato (menu su **Seleziona…**) e campi vuoti, porta compresa; la scheda **Prove** si chiama ora **Test** ed è quella iniziale.
- Il SIP Caller si presenta al server come **MANXX Validator** con la versione dell'app (header `User-Agent`), così il monitor del provider, ad esempio l'advisor di WiC, mostra chi è registrato sulla linea.

## 0.2.0 — 23 ottobre 2026

- **SIP Caller**: nuova sezione per verificare una linea VoIP. Importa i template di provider SIP trunk esportati da 3CX e li propone in un menu; con numero, Auth ID e password si registra sul server, poi fa una chiamata di prova in uscita e risponde a una in entrata, entrambe con test eco (due toni, poi la tua voce). Funziona su qualsiasi rete del Mac (PPPoE, Wi‑Fi, Ethernet), anche dietro NAT. Esito con pacchetti RTP e livello audio, log e traccia SIP completa.

## 0.1.1 — 15 ottobre 2026

- La finestra si apre a 1000 × 615 punti (minimo 960 di larghezza): il risultato del test di velocità resta leggibile senza andare a capo.
- Il test di velocità parte con 8 flussi.

## 0.1.0 — 15 ottobre 2026

Prima versione pubblica.

- **Sessione PPPoE dal Mac** con tag VLAN 802.1Q applicato dall'app, su qualsiasi adattatore Ethernet. Il VLAN ID è facoltativo: se lo lasci vuoto i frame partono senza tag.
- **Trasporto proprio** (`pppoe-relay`, BPF) con `pppd` di sistema, perché il PPPoE di macOS su VLAN non tagga i frame.
- **Una sola autorizzazione** di amministratore per avvio, valida per tutte le connessioni.
- **Riepilogo della sessione**: concentratore (nome e MAC), Session ID, IP, gateway, DNS.
- **Connessione principale** facoltativa: route predefinita e DNS sul PPPoE.
- **Test di velocità multi-flusso** (8, 16 o 32 flussi) con ping, jitter, download, upload, latenza sotto carico e ripartizione tra Cloudflare, Apple CDN e OVH.
- **Log** della negoziazione con messaggi di errore in italiano.
- **Nessun dato salvato**: a ogni avvio i campi sono vuoti.
- **Aggiornamento automatico** all'avvio da GitHub Releases, con verifica della firma Ed25519.
