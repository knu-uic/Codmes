# Codmes accounts and optional Google authentication

A Codmes account UUID is the stable owner of a profile and device registrations on one self-hosted server. Every new account chooses a unique Codmes ID and password (15–128 characters); Google is an optional, replaceable login method. Existing Google-only users configure credentials in place once, retaining their UUID, profile, data and approved devices. Accounts are not global across servers. There are no password hints or recovery keys. If both the local password and linked Google access are lost, automated recovery is not provided.

Passwords are randomly salted and scrypt hashed (`N=32768,r=8,p=3`); hashes and plaintext passwords are never returned by APIs or displayed in Server Manager. Account creation/login and sensitive changes have process-local request limits; limits reset on server restart. KDF concurrency and authentication body size are bounded. The administrator controls the host/database and can still modify it: hashing protects stored credentials, not against a malicious server administrator. Remote account and workspace requests require trusted HTTPS, even if Google is not configured.

Google sign-in is available only with `CODMES_MULTIUSER_ENABLED=true` and configured Google OAuth client IDs. The self-hosted server does not need a Google client secret: native clients obtain an ID token with Google's authorization-code/PKCE flow, then the server verifies its signature against Google's HTTPS JWKS and checks `iss`, `aud`, `azp` (when present), `exp`, `iat`, and the stable `sub` claim. Server Manager's Desktop OAuth token exchange also sends the matching Desktop client secret from the app distributor's build; this is not a per-server setting or a substitute for PKCE. The server never receives a Google password or stores an ID token. Email is display-only; `sub` identifies the Google login method, while the Codmes UUID is the account key.

## Configuration

The Codmes app distributor registers one Google Cloud OAuth project and bundles its OAuth configuration into the official Server Manager and client builds. Each self-hosted server owner creates a Codmes account and optionally connects Google; they do not create an OAuth project, enter client IDs, or use a central Codmes account server. The self-hosted server validates Google ID tokens locally against Google's public keys. Use a **Desktop app** OAuth client for Server Manager and Windows Codmes. The platform registrations are:

| Client | Google Cloud client type | Codmes identifier |
| --- | --- | --- |
| Server Manager / Windows | Desktop app | Loopback redirect on `127.0.0.1` with a temporary port |
| macOS Codmes | iOS (native-app flow) | Bundle ID `com.codmes.app` |
| iOS Codmes | iOS | Bundle ID `com.codmes.app.ios` |
| Android Codmes | Android, plus Web for Credential Manager's server client ID | Package `com.codmes.android` and signing certificate SHA-1 |

For each Apple target, the distributor builds with `CODMES_GOOGLE_CLIENT_ID` and `CODMES_GOOGLE_URL_SCHEME` set to the matching ID and reversed client-ID scheme (`com.googleusercontent.apps.<ID-prefix>`). Apple IDs and URL schemes are embedded in the app and cannot be changed by a server setting. Windows embeds the Desktop ID and matching secret, and Android embeds `CODMES_GOOGLE_WEB_CLIENT_ID` at build time for Credential Manager. Clients reject a server advertising a different publisher ID before starting Google login. Android also needs the signed APK's Android registration at Google. A secret embedded in a native app is extractable and is not a security boundary; PKCE remains required.

There is no central Codmes account database or authentication broker. A Google identity can be an administrator on one server, an approved client on another, and unapproved on a third. Sessions, registrations, approval modes and profile access are stored in each server's own PostgreSQL database. Changing an administrator or deleting a registration affects only that server. Initial administrator and default profile creation use one database transaction; a PIN is not required.

Google's [native app OAuth guide](https://developers.google.com/identity/protocols/oauth2/native-app) describes desktop/iOS registration and PKCE; the [Android Credential Manager guide](https://developer.android.com/identity/sign-in/credential-manager-siwg-implementation) describes Android and Web client IDs. The server verifies the returned ID token against Google's public keys and allowed audiences.

- `CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_ID`, `CODMES_BUNDLED_GOOGLE_MACOS_CLIENT_ID`, `CODMES_BUNDLED_GOOGLE_IOS_CLIENT_ID`, `CODMES_BUNDLED_GOOGLE_ANDROID_CLIENT_ID`, `CODMES_BUNDLED_GOOGLE_WEB_CLIENT_ID`: Public IDs embedded at Server Manager build time by the Codmes distributor. Tagged release builds require all five. The build workflow reads the corresponding GitHub repository variables named `CODMES_GOOGLE_*_CLIENT_ID`.
- `CODMES_BUNDLED_GOOGLE_DESKTOP_CLIENT_SECRET`: Matching Desktop app OAuth client secret from the distributor's Google Cloud JSON. Server Manager includes it in Google's token exchange; never publish the JSON or commit this value. Tagged Server Manager releases require the GitHub Actions secret `CODMES_GOOGLE_DESKTOP_CLIENT_SECRET`. Local builds may supply it in the ignored `apps/server-manager/.env` file. It is not sent to the self-hosted Codmes server.
- Server Manager uses only OAuth credentials bundled at build time. It does not read per-server OAuth settings. The downloaded Google Desktop OAuth JSON has an `installed` object containing the matching `client_id` and `client_secret`; provide both to the distributor build without committing the JSON. Windows client builds also embed that Desktop secret because they perform their own token exchange. Native app binaries cannot keep an embedded secret confidential, so PKCE and ID-token verification remain necessary.
- For a directly launched server without Server Manager, `CODMES_GOOGLE_DESKTOP_CLIENT_ID`: Server Manager and Windows native loopback OAuth client ID.
- `CODMES_GOOGLE_MACOS_CLIENT_ID`: macOS Codmes native OAuth client ID.
- `CODMES_GOOGLE_IOS_CLIENT_ID`: iOS native OAuth client ID.
- `CODMES_GOOGLE_ANDROID_CLIENT_ID`: Android native OAuth client ID.
- `CODMES_GOOGLE_WEB_CLIENT_ID`: Web client ID used as the Android backend audience where required.
- `CODMES_GOOGLE_OAUTH_CLIENT_IDS`: Optional comma-separated additional allowed audiences.
- `CODMES_MANAGER_BOOTSTRAP_SECRET`: Random secret of at least 32 characters supplied only to the local Server Manager process and backend. Required in `X-Codmes-Manager-Secret` for administrator Google endpoints and client-registration administration. This is not an OAuth client secret.
- `CODMES_TLS_CERT` and `CODMES_TLS_KEY`: Both absolute paths to a TLS certificate chain PEM and private-key PEM. If both are set, the server serves HTTPS; if neither is set, it serves HTTP. Setting only one fails startup.

The certificate must be trusted by each client and contain Subject Alternative Names for both the server's LAN address/name and `127.0.0.1` if the Server Manager connects locally by IP. Codmes does not silently create a self-signed certificate or disable certificate verification. In multiuser mode, **every non-loopback API and WebSocket request requires HTTPS**. Only health and public Google configuration remain readable over plain HTTP. ID/password accounts work without Google configuration.

## Codmes credential API

- `POST /api/auth/admin/bootstrap` `{username,password}`: first administrator only, empty server, loopback plus Manager secret. The account and default profile commit atomically.
- `POST /api/auth/admin/login` `{username,password}`: Manager secret required; returns a Manager session only for an active administrator.
- `POST /api/auth/client/register` and `/api/auth/client/login` `{username,password,deviceId,deviceName?}`: same pending/approved/rejected flow as Google. No client signup can create an administrator.
- `GET /api/auth/account`: `{user}`; use an account token, never a profile token. Administrator management also requires a Manager session and secret.
- `POST /api/auth/account/credentials` `{username,password}`: one-time in-place setup for an authenticated existing Google-only account.
- `POST /api/auth/account/password` `{currentPassword,password}`: verify current password, replace hash, revoke other sessions, preserve the current session.
- `POST /api/auth/account/google/link` `{currentPassword,idToken}`: explicit link/change to a freshly verified Google identity; reject a Google identity owned by another account. Never infer identity from email.
- `POST /api/auth/account/google/unlink` `{currentPassword}`: remove Google only; keep Codmes account, password, profile and device registrations. Sensitive changes revoke other sessions, preserving the current account session. Concurrent changes recheck account/session state under a database lock.

Migration 008 replaces the Google-dependent profile FK and device registration key with Codmes UUID ownership, without regenerating IDs or deleting data.

## Google API

`GET /api/google-auth/config` is public and returns `enabled`, `clientIds` (`desktop`, `macos`, `ios`, `android`, `web`), `bootstrapRequired`, `adminLinked`, `approvalMode`, `requiresSecureTransport`, and `managerSecretConfigured`, and `passwordEnabled`.

Server Manager calls, restricted to loopback and `X-Codmes-Manager-Secret`:

- `POST /api/google-auth/admin/bootstrap` with `{idToken, username, password, workspaceName?}` only when no account exists. Returns `{token,expiresAt,user,workspace}`.
- `POST /api/google-auth/admin/login` with `{idToken,deviceName?}` after the administrator's Google identity has been linked. Returns `{token,expiresAt,user}`.
- `POST /api/google-auth/admin/change` with a current manager bearer token and `{idToken,currentPassword}`. Changes the Google login method, returns `{user}`, and retains the current session; other account/profile sessions are revoked. Account/profile/device IDs are preserved.
- `GET /api/admin/client-registrations` returns `{mode,registrations}`. `PUT /api/admin/client-registrations/mode` takes `{mode:'ask'|'allow'}`. `POST /api/admin/client-registrations/:id/approve`, `/reject`, and `/remove` update a device registration. Rejection/removal revokes its account and profile sessions.

Codmes client calls:

- `POST /api/google-auth/client/login` with `{idToken,deviceId,deviceName,username?,password?}`. For a new or unconfigured Google identity, returns `account_setup_required` without creating an account or issuing a session. Repeat with the freshly verified ID token and desired Codmes credentials. Existing Google administrator credentials must be configured in Server Manager. An already-used ID never auto-merges accounts; sign in to the existing Codmes account and explicitly link Google. `deviceId` must be a persistent, randomly generated 256-bit base64url secret, not a hardware identifier. An approved device receives `{status:'approved',token,expiresAt,user}`. A new device receives `{status:'pending',requestId,requestToken}`; a rejected one receives `{status:'rejected',requestId}`.
- `POST /api/google-auth/client/status` with `{requestId,requestToken}`. Returns pending/rejected, or issues a Codmes token once after approval. Preserve the original `requestToken`; it is not repeated in pending poll responses. It expires after ten minutes; the client can obtain a fresh one by repeating either login method.
- `GET /api/client/profile` returns the Codmes account (`id`, `username`, `displayName`, `email`, `googleLinked`, `credentialsConfigured`) and its own profile, or `setupRequired:true` if it has not been created yet.
- `POST /api/client/profile/register` with `{}` automatically ensures one profile per Codmes account on this server. It is idempotent and serializes simultaneous first logins. No profile name or PIN is supplied by the client. Only approved client account sessions can call this endpoint. After creation, `POST /api/profiles/:id/open` with `{}` issues a profile-scoped token for that account's bound profile only. Account tokens cannot directly use workspace APIs.

The same Codmes account uses the same profile on every approved device on a given server. Other Codmes accounts never see or open that profile, even if old shared membership rows still exist. Migration 007 adopts only an unambiguous already-owned active profile; unrelated shared profiles and their data are preserved for manager access, not reassigned. Client profile creation UI is removed. Profile deletion archives server data and revokes existing profile sessions; a later connection can create a new active profile, while old data remains in Server Manager.

Optional **app lock** is device-local, disabled by default, and separate from Codmes identity and server authorization. Its four-digit PIN is salted PBKDF2-SHA256 hashed and stored in the device's secure storage (Apple Keychain, Windows DPAPI, Android Keystore-encrypted preferences). Changing/disabling it requires the current local PIN; five incorrect attempts block further checks for a minute in the running app. It locks the UI on launch and when leaving the app; it does not encrypt workspace files or revoke the Google session. Server Manager cannot view/reset device PINs. Existing server profile PIN hashes are preserved for compatibility with manager-side operations, but Google client sessions do not use them.

`ask` requires explicit approval for every new Codmes account and device. **`allow` automatically accepts newly registered Codmes accounts and devices, regardless of login method. Anyone who can reach the server can sign up and obtain access while this mode is on.** Use `allow` only on a trusted network with an intended open-membership policy. An explicitly rejected device remains rejected until an administrator removes its registration. Deleting a device registration revokes its sessions, including any open profile sessions. A Google account may be an administrator for Server Manager but its Codmes client sessions are down-scoped to ordinary client permissions.
