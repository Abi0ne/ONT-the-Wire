# Novità

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
