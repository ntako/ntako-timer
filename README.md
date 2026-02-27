# NTAKO Timer

App Pomodoro Timer cross-platform (web + Android + iOS) con task list integrata e sincronizzazione cloud opzionale.

- **Frontend**: Flutter (web + mobile)
- **Backend**: PHP puro + MySQL — hostabile su qualsiasi hosting economico (Altervista, Aruba, ecc.)
- **Architettura**: local-first — funziona offline, sincronizza se l'utente è registrato

---

## Struttura del progetto

```
NTAKO_TIMER/
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

Modifica `.env` con le credenziali desiderate (non usare i valori di default in produzione):

```
MYSQL_ROOT_PASSWORD=rootpass
MYSQL_DATABASE=ntako_timer
MYSQL_USER=ntako_user
MYSQL_PASSWORD=ntako_pass
JWT_SECRET=cambia_questo_con_una_stringa_casuale_di_64_caratteri
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
| GET    | `/api/sync/pull`      | Scarica modifiche dal server       |
| POST   | `/api/sync/push`      | Carica modifiche locali sul server |

Il token JWT va incluso come `Authorization: Bearer <token>` nelle richieste `/sync/*`.

---

## Deploy in produzione

### Backend (hosting condiviso con PHP + MySQL)

1. **Carica i file** — tramite FTP, carica il contenuto di `backend/` in `public_html/`.

2. **Crea il database** — dal pannello di controllo dell'hosting (es. cPanel) crea un database MySQL e un utente.

3. **Importa lo schema** — importa `backend/schema.sql` tramite phpMyAdmin.

4. **Configura le credenziali** — modifica `backend/config/database.php` con i dati del database reale:

   ```php
   // Alternativa per hosting senza variabili d'ambiente:
   // sostituisci getenv('DB_HOST') con la stringa diretta
   $host = 'localhost';
   $db   = 'nome_database';
   $user = 'utente_db';
   $pass = 'password_db';
   ```

   > Non committare mai questo file con credenziali reali.

5. **Imposta il JWT secret** — in `backend/middleware/Auth.php`, oppure usando le variabili d'ambiente del pannello hosting se disponibili.

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
| Sincronizzazione | Last-write-wins su `updated_at`; soft-delete via `deleted_at` |
| Timer in background | `targetEndTime` (timestamp assoluto) ricalcolato a ogni `onAppResume()` |
| Notifiche | `flutter_local_notifications` con `TZDateTime`; no-op su web |
| JWT | HMAC-SHA256 manuale in PHP — nessun Composer richiesto |
