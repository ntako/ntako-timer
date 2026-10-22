// HTTP client for the NTAKO backend (same API as the app and the Cardputer).

import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Soup from 'gi://Soup?version=3.0';
import Secret from 'gi://Secret';

Gio._promisify(Soup.Session.prototype, 'send_and_read_async', 'send_and_read_finish');
Gio._promisify(Secret, 'password_store', 'password_store_finish');
Gio._promisify(Secret, 'password_lookup', 'password_lookup_finish');
Gio._promisify(Secret, 'password_clear', 'password_clear_finish');

/** Upper bound for a whole request: the UI must always get an answer. */
const DEADLINE_SECONDS = 30;

export class ApiError extends Error {
    constructor(message, status = 0) {
        super(message);
        this.status = status;
    }
}

// ── Token in the system keyring ──────────────────────────────────────────────

const SECRET_SCHEMA = new Secret.Schema('com.ntako.Timer', Secret.SchemaFlags.NONE,
    {server: Secret.SchemaAttributeType.STRING});

/** Token for `server`, null when not logged in. */
export async function loadToken(server) {
    try {
        return await Secret.password_lookup(SECRET_SCHEMA, {server}, null);
    } catch (e) {
        logError(e, 'ntako-timer: keyring lookup failed');
        return null;
    }
}

export function saveToken(server, token) {
    return Secret.password_store(SECRET_SCHEMA, {server}, Secret.COLLECTION_DEFAULT,
        'NTAKO Timer', token, null);
}

export function clearToken(server) {
    return Secret.password_clear(SECRET_SCHEMA, {server}, null);
}

// ── Requests ─────────────────────────────────────────────────────────────────

/** Trims, drops trailing slashes, assumes https://; null when not a URL. */
export function normalizeBaseUrl(input) {
    let url = String(input ?? '').trim().replace(/\/+$/, '');
    if (url && !url.includes('://'))
        url = `https://${url}`;
    const uri = GLib.Uri.parse(url, GLib.UriFlags.NONE);
    return uri && ['http', 'https'].includes(uri.get_scheme()) && uri.get_host() ? url : null;
}

export class ApiClient {
    /**
     * @param {() => string} baseUrl  current server address
     * @param {() => Promise<?string>} token  current token, null if none
     */
    constructor(baseUrl, token) {
        this._baseUrl = baseUrl;
        this._token = token;
        this._session = new Soup.Session({timeout: 15, user_agent: 'ntako-timer-gnome'});
    }

    get(path, params = {}) {
        const query = Object.entries(params)
            .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
        return this._request('GET', query ? `${path}?${query}` : path);
    }

    post(path, body) {
        return this._request('POST', path, body);
    }

    async _request(method, path, body) {
        const base = this._baseUrl();
        const url = `${base}${path}`;
        const msg = Soup.Message.new(method, url);
        if (!msg)
            throw new ApiError(`Indirizzo del server non valido: ${base}`);
        if (!path.startsWith('/auth/')) {
            const token = await this._token();
            if (token)
                msg.request_headers.append('Authorization', `Bearer ${token}`);
        }
        if (body !== undefined) {
            msg.set_request_body_from_bytes('application/json',
                new GLib.Bytes(new TextEncoder().encode(JSON.stringify(body))));
        }

        const cancellable = new Gio.Cancellable();
        const deadline = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, DEADLINE_SECONDS, () => {
            cancellable.cancel();
            return GLib.SOURCE_REMOVE;
        });
        let bytes;
        try {
            bytes = await this._session.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, cancellable);
        } catch (e) {
            if (cancellable.is_cancelled())
                throw new ApiError(`Il server ${GLib.Uri.parse(url, 0)?.get_host()} non risponde (timeout).`);
            throw new ApiError(`Impossibile connettersi al server: ${e.message}`);
        } finally {
            if (!cancellable.is_cancelled())
                GLib.source_remove(deadline);
        }

        const status = msg.get_status();
        const text = new TextDecoder().decode(bytes.get_data() ?? new Uint8Array());
        let data = null;
        try {
            data = JSON.parse(text);
        } catch {
            // Hosting error pages are HTML: keep data null.
        }
        if (status >= 200 && status < 300 && data !== null)
            return data;
        if (data && typeof data.error === 'string')
            throw new ApiError(data.error, status);
        throw new ApiError(status
            ? `Risposta inattesa dal server (HTTP ${status}).`
            : 'Nessuna risposta dal server.', status);
    }

    /**
     * Checks that `baseUrl` answers like an NTAKO backend: an unauthenticated
     * pull must be a 401 with a JSON error. Null when it does, else a message.
     */
    static async checkServer(baseUrl) {
        const client = new ApiClient(() => baseUrl, async () => null);
        try {
            await client.get('/sync/pull');
            return 'Il server risponde, ma non come un backend NTAKO.';
        } catch (e) {
            if (e.status === 401)
                return null;
            if (e.status === 404) {
                return 'Nessun backend NTAKO a questo indirizzo (HTTP 404). ' +
                    'Controlla il percorso: di solito finisce con /api.';
            }
            return e.message;
        }
    }
}
