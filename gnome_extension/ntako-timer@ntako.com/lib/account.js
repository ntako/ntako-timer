// Account state shared by the panel and the preferences window: the server
// address and email live in GSettings, the token in the system keyring.

import {ApiClient, loadToken, saveToken, clearToken} from './api.js';

export const isLoggedIn = settings =>
    settings.get_string('account-email') !== '' && settings.get_string('server-url') !== '';

/** Client always pointed at the server currently configured. */
export function createApi(settings) {
    return new ApiClient(
        () => settings.get_string('server-url'),
        () => loadToken(settings.get_string('server-url')));
}

/** Logs in (or registers) and starts the next sync from scratch. */
export async function login(settings, store, {email, password, register = false}) {
    const res = await createApi(settings).post(register ? '/auth/register' : '/auth/login',
        {email, password});
    await saveToken(settings.get_string('server-url'), res.token);
    // The stored pull position may belong to another account.
    store.update(d => {
        d.meta.syncCursor = 0;
        d.meta.lastSyncError = null;
    });
    settings.set_string('account-email', res.user.email);
}

export async function logout(settings) {
    try {
        await clearToken(settings.get_string('server-url'));
    } catch (e) {
        logError(e, 'ntako-timer: clearing the token failed');
    }
    settings.set_string('account-email', '');
}
