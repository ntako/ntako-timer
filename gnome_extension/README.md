# NTAKO Timer — estensione GNOME Shell

Client desktop con le stesse funzioni dell'app: timer, task e categorie,
storico con filtri e grafici, account e sincronizzazione, import/export.
GNOME Shell 46–50.

- **Barra in alto**: tempo che scorre, menu con scelta del task, avvia /
  pausa / riprendi / ferma, totale di oggi, sincronizza.
- **Finestra** (menu → *Task, storico e impostazioni…*, oppure
  `gnome-extensions prefs ntako-timer@ntako.com`): pagine Task, Storico,
  Account, Impostazioni.

## Installazione

```bash
./install.sh            # link simbolico alla cartella del repo
gnome-extensions enable ntako-timer@ntako.com
```

Su Wayland, la prima volta bisogna uscire e rientrare nella sessione prima
di poterla attivare.

## Come funziona

| Cosa | Dove |
|---|---|
| Dati (categorie, task, sessioni, stato del timer) | `~/.local/share/ntako-timer/data.json`, condiviso da barra e finestra |
| Impostazioni, server, email | GSettings `org.gnome.shell.extensions.ntako-timer` |
| Token di accesso | portachiavi di sistema (libsecret), per server |

Funziona anche senza account; con l'account sincronizza col backend usando
lo stesso protocollo dell'app (push/pull a cursore, stesse regole di unione).
A differenza dell'app, anche la pausa è salvata: il tempo in pausa non viene
mai contato, nemmeno se GNOME Shell si riavvia.

Storico, CSV e backup JSON seguono le stesse regole e gli stessi formati
dell'app e del pannello admin: un backup fatto da uno si importa negli altri.

## Test

```bash
gjs -m tests/run.js                              # librerie
gjs -m tests/run.js http://localhost:18080/api   # + sync contro un backend
```
