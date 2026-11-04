# Workadoro

App Time Tracker cross-platform (web + Android + iOS) con task list integrata e sincronizzazione cloud opzionale.

- **Frontend**: Flutter (web + mobile)
- **Backend**: PHP puro + MySQL — hostabile su qualsiasi hosting economico (Altervista, Aruba, ecc.)
- **Architettura**: local-first — funziona offline, sincronizza se l'utente è registrato

---

## Struttura del progetto

```
workadoro/
├── docker-compose.yml       ← ambiente di sviluppo locale
├── .env.example             ← template variabili d'ambiente
├── backend/                 ← API PHP
│   ├── schema.sql           ← schema database MySQL
│   ├── index.php            ← router principale
│   ├── .htaccess
│   ├── config/database.php
│   ├── middleware/Auth.php  ← JWT HMAC-SHA256
│   └── api/
│       ├── auth/            ← register, login
│       └── sync/            ← pull, push
└── flutter_app/             ← app Flutter
    └── lib/
        ├── core/            ← database (Drift), network, storage, notifiche
        └── features/        ← timer, tasks, auth, settings, sync
```

---

## Sviluppo locale

### Prerequisiti

- [Docker](https://docs.docker.com/get-docker/) + Docker Compose
- [Flutter](https://docs.flutter.dev/get-started/install) ≥ 3.19

### 1. Configura le variabili d'ambiente

```bash
cp .env.example .env
```

Modifica `.env` con le credenziali desiderate. `JWT_SECRET` e `ADMIN_PASS` sono obbligatori: se mancano o sono ancora i segnaposto, l'API risponde 500 e il pannello admin resta disabilitato. Per generarli: `openssl rand -hex 32`.

```
MYSQL_ROOT_PASSWORD=rootpass
MYSQL_DATABASE=workadoro
MYSQL_USER=workadoro_user
MYSQL_PASSWORD=workadoro_pass
JWT_SECRET=<output di openssl rand -hex 32>
ADMIN_PASS=<password del pannello admin>
```

### 2. Avvia il backend

```bash
docker compose up -d
```

Il primo avvio scarica le immagini e inizializza il database con `backend/schema.sql`.

Verifica che funzioni:

```bash
curl -X POST http://localhost:8080/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"test@example.com","password":"password123"}'
# → { "token": "eyJ...", "user": { "id": 1, "email": "test@example.com" } }
```

### 3. Installa le dipendenze Flutter

```bash
cd flutter_app
flutter pub get
```

### 4. Avvia l'app

**Web** (richiede gli header COOP/COEP per Drift WASM):

```bash
flutter run -d chrome \
  --dart-define=API_BASE_URL=http://localhost:8080/api \
  --web-header "Cross-Origin-Opener-Policy=same-origin" \
  --web-header "Cross-Origin-Embedder-Policy=require-corp"
```

**Android** (emulatore — `10.0.2.2` punta al localhost dell'host):

```bash
flutter run -d emulator-5554 \
  --dart-define=API_BASE_URL=http://10.0.2.2:8080/api
```

**Android** (dispositivo fisico — sostituisci con l'IP della tua macchina):

```bash
flutter run -d <device-id> \
  --dart-define=API_BASE_URL=http://192.168.1.x:8080/api
```

---

## Generazione codice (Drift + Riverpod)

Dopo aver modificato tabelle, DAOs o provider, rigenera i file `.g.dart`:

```bash
cd flutter_app
dart run build_runner build --delete-conflicting-outputs
```

---

## API Backend

| Metodo | Endpoint              | Descrizione                        |
|--------|-----------------------|------------------------------------|
| POST   | `/api/auth/register`  | Registra un nuovo utente           |
| POST   | `/api/auth/login`     | Accedi e ottieni un JWT            |
| GET    | `/api/sync/pull`      | Scarica modifiche dal server (`?cursor=N&limit=200` incrementale e paginato; `?since=0` istantanea completa, usata dal Cardputer) |
| POST   | `/api/sync/push`      | Carica modifiche locali sul server |
| GET    | `/api/presence/config` | Impostazioni presenze dell'utente (policy, modalità) e luoghi da rilevare |
| POST   | `/api/presence/places` | Crea/modifica/elimina luoghi dell'utente (solo con policy `user`, altrimenti 403) |
| POST   | `/api/presence/push`   | Invia le permanenze rilevate dal dispositivo |
| GET    | `/api/presence/stays`  | Permanenze di tutti i dispositivi dell'utente (`?from=&to=` in ms), per il report nell'app |

Il token JWT va incluso come `Authorization: Bearer <token>` nelle richieste `/sync/*`.

---

## Rilevamento presenze (badge)

I client possono comportarsi come un badge: riconoscono quando il dispositivo è in un luogo noto, tramite GPS e/o rete Wi-Fi, e registrano entrata, uscita e permanenza.

**Policy** — impostata dall'admin per la piattaforma (dashboard del pannello) e, se serve, sovrascritta per il singolo utente (pagina utente):

| Policy  | Modalità di rilevamento | Luoghi |
|---------|-------------------------|--------|
| `off`   | — (funzione disattivata) | — |
| `admin` | decisa dall'admin | gestiti solo dall'admin |
| `user`  | scelta su ogni dispositivo (quella dell'admin è il suggerimento) | l'utente crea i propri dall'app |

**Modalità**: solo GPS, solo Wi-Fi, GPS **e** Wi-Fi (entrambi devono confermare), GPS **o** Wi-Fi (basta uno). In "e"/"o" contano i criteri che il luogo definisce: un luogo con sola posizione è rilevato dal solo GPS.

**Luoghi**: della piattaforma (visibili a tutti, gestiti dalla dashboard) o del singolo utente. Ognuno ha posizione + raggio (che deve comprendere lo scarto del GPS) e/o reti Wi-Fi: un nome (SSID, vale ogni access point) o l'indirizzo di un access point (BSSID).

**Regole di rilevamento** (`flutter_app/lib/features/presence/presence_logic.dart`):
- GPS "dentro" se la posizione è entro il raggio con una precisione sufficiente; "fuori" solo se nemmeno l'errore stimato raggiunge il raggio; altrimenti non decide.
- Wi-Fi: confronta la rete a cui il dispositivo è connesso.
- Frequenza dei controlli scelta su ogni dispositivo: ogni 1, 2, 5 o 10 minuti (meno controlli, meno batteria).
- Entrata alla prima conferma; uscita confermata dopo almeno due controlli negativi (minimo 3 minuti), registrata all'ultimo rilevamento positivo. Senza informazioni per 30 minuti (o app chiusa) la permanenza si chiude all'ultimo rilevamento.

**App**: Impostazioni → Presenze. Il rilevamento va acceso su ogni dispositivo (servono i permessi di posizione: Android e iOS considerano dato di posizione anche il nome della rete Wi-Fi).

Su Android il rilevamento è un servizio in background a sé (`flutter_foreground_task`, tipo "location", con notifica che indica dove sei): continua anche chiudendo l'app dal multitasking e riparte dopo un aggiornamento dell'app. Per non essere sospeso serve escluderlo dall'ottimizzazione batteria, e per ripartire dopo un riavvio del telefono la posizione deve essere su "Consenti sempre": la schermata Presenze lo segnala con un pulsante. La sezione **Diagnostica** elenca avvii, pause ("Nessun controllo per…"), entrate e uscite del dispositivo. Sul web la rete Wi-Fi non è leggibile (solo GPS, a pagina aperta). Su iOS, per leggere la rete Wi-Fi serve anche la capability *Access WiFi Information* nel profilo di firma.

**Report**, come per i task, con filtri periodo / luogo / raggruppamento e vista Grafici o Elenco:
- pannello admin: pagina utente → scheda **Presenze**;
- app: Impostazioni → Presenze → **Report presenze** (dati di tutti i dispositivi dal server, più quelli di questo dispositivo non ancora inviati).

Grafici: ore per giorno/settimana/mese impilate per luogo, ore per luogo, orari tipici (entrata e uscita medie, media al giorno), fasce orarie giorno per giorno (periodi fino a 31 giorni). Elenco: riepilogo per giorno (prima entrata, ultima uscita, permanenza) e tutte le permanenze registrate, con dispositivo e metodo di rilevamento.

Le permanenze di più dispositivi nello stesso luogo sono unite (il tempo non è contato due volte) e una permanenza a cavallo della mezzanotte è divisa tra i due giorni. Ogni luogo ha un colore fisso (palette di 8 colori, in ordine di creazione; dal nono in poi grigio).

Non ancora supportato dall'estensione GNOME e dal Cardputer.

---

## Deploy in produzione

### Backend (hosting condiviso con PHP + MySQL)

1. **Carica i file** — tramite FTP, carica il contenuto di `backend/` in `public_html/`.

2. **Crea il database** — dal pannello di controllo dell'hosting (es. cPanel) crea un database MySQL e un utente.

3. **Importa lo schema** — importa `backend/schema.sql` tramite phpMyAdmin.
   Se il database esiste già, esegui invece (una sola volta) le migrazioni non ancora applicate, ad es. `backend/schema_migration_002_sync_version.sql`. Per il rilevamento presenze: `backend/schema_migration_004_presence.sql`.

4. **Configura le credenziali** — copia `config/local.php.example` in `config/local.php` sul server e compila database, `JWT_SECRET` e `ADMIN_PASS` (genera i secret con `openssl rand -hex 32`). Senza `JWT_SECRET` l'API risponde 500; senza `ADMIN_PASS` il pannello admin è disabilitato.

   > `config/local.php` è in `.gitignore`: non committarlo mai.

### App Flutter — Web

```bash
cd flutter_app
flutter build web \
  --dart-define=API_BASE_URL=https://tuodominio.com/api \
  --release
```

La cartella `build/web/` contiene l'app statica. Caricala su:

- **Hosting condiviso**: carica il contenuto di `build/web/` in una sottocartella o su un sottodominio.
- **Firebase Hosting** (gratuito): `firebase deploy --only hosting`
- **Netlify / Vercel**: trascina `build/web/` nell'interfaccia web.

> **Importante**: il server che serve l'app web deve rispondere con gli header:
> ```
> Cross-Origin-Opener-Policy: same-origin
> Cross-Origin-Embedder-Policy: require-corp
> ```
> Questi sono necessari per Drift WASM (SQLite nel browser). Su Apache aggiungili a `.htaccess`; su Nginx al blocco `location`.

### App Flutter — Android / iOS

```bash
# Android (APK)
flutter build apk --dart-define=API_BASE_URL=https://tuodominio.com/api --release

# Android (App Bundle per Play Store)
flutter build appbundle --dart-define=API_BASE_URL=https://tuodominio.com/api --release

# iOS
flutter build ipa --dart-define=API_BASE_URL=https://tuodominio.com/api --release
```

---

## Note tecniche

| Aspetto | Soluzione |
|---|---|
| DB locale | Drift — SQLite su mobile, WASM+IndexedDB su web |
| Sincronizzazione | Last-write-wins su `updated_at`; soft-delete via `deleted_at`; pull incrementale su `version`, contatore per utente assegnato dal server (immune allo sfasamento degli orologi) |
| Timer in background | `targetEndTime` (timestamp assoluto) ricalcolato a ogni `onAppResume()` |
| Notifiche | `flutter_local_notifications` con `TZDateTime`; no-op su web |
| JWT | HMAC-SHA256 manuale in PHP — nessun Composer richiesto |
