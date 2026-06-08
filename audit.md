# GlowSonic code audit

Status: the findings below were addressed in the current working tree after the audit. The notes are kept as release-readiness context and as a checklist for future regressions.

Scope: quick release-readiness audit of the LMS plugin code, with a focus on critical issues and places where the happy path is assumed. Small local-only polish issues are intentionally omitted.

## Highest priority findings

### 1. Token authentication is effectively not implemented

**Where:** `GlowSonic/API.pm`, `GlowSonic/API/Async.pm`, `GlowSonic/ProtocolHandler.pm`

`auth_type => token` is exposed in settings, but the code never creates a salt/token pair. When `token`/`salt` are missing, `_build_params()` falls back to sending `p=<password>`. `authenticate()` only pings with password auth and never calls `_compute_token()` or stores `salt`/`token`. Streaming and cover-art URLs also always use `p=<password>`.

**Impact:**

- Servers or users that disable legacy password auth will fail even though the UI says token auth is selected.
- The plugin silently downgrades to password auth, and `API::Async::authenticate()` can permanently mutate the client to `auth_type = password` after some auth failures.
- Passwords are put into stream and image URLs.

**Recommendation:** generate a random salt client-side and use `t=md5(password . salt)&s=<salt>` for normal API calls, stream URLs, and cover-art URLs. If password fallback is kept, make it explicit and visible rather than automatic/silent.

### 2. Passwords are embedded in playable, image, and metadata URLs

**Where:** `API.pm::stream_url()`, `API.pm::cover_art_url()`, `ProtocolHandler.pm::_stream_url_from_glows()`, `ProtocolHandler.pm::_cover_url()`, settings template

`glows://` URLs include `server`, `user`, and `pass`; the real `/rest/stream` and `/rest/getCoverArt` URLs also include the password. These URLs can end up in LMS logs, saved playlists/favorites, browser requests, database rows, and debug output. `_redact_url()` helps only for some explicit log lines.

**Impact:** not catastrophic for a trusted LAN, but it is a bad look for a community release and makes accidental credential leakage likely.

**Recommendation:** avoid storing credentials in `glows://` URLs. Store only the track/container id and have the protocol handler read current prefs when opening the stream. For browser-visible cover art, either use token auth with per-request salt/token or add a small LMS-side proxy endpoint.

### 3. Settings and URL inputs are not validated before use

**Where:** `Settings.pm`, `API.pm::new()`, `API::Async::call()`, `ProtocolHandler.pm::_stream_url_from_glows()`, `ProtocolHandler.pm::getNextTrack()`

The code assumes `server_url`, API version, artwork size, bitrate, and transcoding format are sane. A missing scheme, whitespace, unsupported scheme, malformed URL, or non-numeric bitrate/art size can produce broken Subsonic URLs. Playback then usually fails silently: `getNextTrack()` calls `$success_cb->()` even if the generated stream URL is invalid and no HTTP/HTTPS delegate can handle it.

**Impact:** one typo in settings can lead to confusing UI/playback failures instead of a clear error message.

**Recommendation:** validate on save and before API/stream construction:

- `server_url` must be `http://` or `https://`, non-empty when browsing/playing, and trimmed.
- `artwork_size` and `transcode_bitrate` should be integers with reasonable bounds.
- `transcode_format` should be one of the supported values.
- In protocol handling, call `$error_cb` or return a visible failure when the stream URL/delegate is invalid.

## Happy-path assumptions worth hardening

### 4. API success handlers assume exact response shape

**Where:** `API/Async.pm` and feed builders in `Plugin.pm`

Most methods assume successful responses have exactly the expected nested hash/array structure, for example `playlists->{playlist}`, `songsByGenre->{song}`, `similarSongs2->{song}`, `artists->{index}`, album `song`, playlist `entry`, etc. If a compatible server omits a field, returns an empty object, returns a singleton object instead of an array, or returns a slightly different shape, feed rendering can die instead of showing an error/empty state.

**Impact:** older Subsonic forks or edge-case libraries can break the LMS request handler despite the HTTP/API status being `ok`.

**Recommendation:** add small helpers such as `_as_hash()` and `_as_array()` and use them consistently before dereferencing/iterating. Also consider wrapping async success-callback bodies in `eval` inside `API::Async::call()` so a parser/feed bug logs an error and calls `error_cb` instead of escaping into LMS.

### 5. Track-info code assumes pluginData is always present

**Where:** `Plugin.pm::_track_info_menu()` and `_track_info_search_*()`

For `glows://` tracks the code immediately does `$track->pluginData->{passthrough}`. Tracks restored from playlists/favorites or created by other LMS paths may not have that pluginData shape. The follow-up search callbacks also assume passthrough and a configured API client.

**Impact:** opening the More/Track Info menu for a restored GlowSonic track can fail instead of simply showing fewer menu items.

**Recommendation:** guard every object access (`$track`, `pluginData`, passthrough array/hash), fall back to parsing metadata from the `glows://` URL, and return an empty menu/result if `_ensure_api()` fails.

### 6. Favorites URLs are inconsistent and likely broken for several item types

**Where:** `Plugin.pm::_full_url()`, uses of `favorites_url`, `ProtocolHandler.pm::explodePlaylist()`

Albums/playlists use `glowsonic://album/...` and `glowsonic://playlist/...`, which `explodePlaylist()` can expand. Other places build HTTP favorites like `/plugins/glowsonic/index.html?type=...`, but no matching `index.html` or web endpoint exists in the repo, and the path casing differs from the shipped `GlowSonic` HTML directory.

**Impact:** saving/restoring favorites for artists, artist radio, genre pages, and some song contexts may lead to dead links or 404s.

**Recommendation:** either remove unsupported `favorites_url` values for now, or implement a real OPML/web endpoint for them. For playable containers, prefer explicit `glowsonic://...` URLs and extend `explodePlaylist()` if more container types are needed.

### 7. Playlist expansion does not surface configuration/auth failures

**Where:** `ProtocolHandler.pm::explodePlaylist()`, `_api_client_from_prefs()`

`explodePlaylist()` builds an API client from prefs even when server URL or credentials are empty. On failure it returns an empty OPML playlist. That is safe, but not helpful.

**Impact:** favorites/presets can appear empty with no user-facing reason after settings changes or auth failures.

**Recommendation:** check configuration before calling the API and return a single OPML error item such as “GlowSonic is not configured” or “Could not load playlist: auth failed”.

### 8. Scrobbling marks tracks played immediately

**Where:** `Plugin.pm::_on_play_notification()`, `API/Async.pm::scrobble()`

Every `playlist newsong` immediately sends `submission=true`, which Navidrome treats as played. There is no duration threshold, duplicate suppression, or guard around some LMS object access.

**Impact:** skipped tracks may be marked as played. Network/auth errors are logged, but playback state and duplicate notifications are not considered.

**Recommendation:** for release quality, delay final scrobble until a simple threshold is met, e.g. 50% played or 4 minutes, and send it once per track play. Keep current behavior behind an “eager scrobble” preference only if desired.

## Lower priority but still release-relevant

### 9. The settings page renders the stored password back into the HTML form

**Where:** `GlowSonic/HTML/EN/plugins/GlowSonic/settings/basic.html`, `Settings.pm::handler()`

The save handler supports “all stars means unchanged”, but the template currently fills the password input with the actual stored password, not stars. This exposes the password to anyone who can open the LMS settings page or inspect the HTML.

**Recommendation:** render a masked placeholder or an empty password field with “leave blank to keep existing password” semantics.

### 10. Blocking sync binary helpers use decoded content and full buffering

**Where:** `API/Sync.pm::get_cover_art()`, `API/Sync.pm::stream_track()`

These methods use `decoded_content`, and `stream_track()` loads the whole audio response into memory. They appear unused for normal playback, but if reused later they can corrupt binary data or cause memory spikes.

**Recommendation:** use raw `content` for cover art/audio and avoid full-track buffering unless this module is removed or clearly marked as test-only.

## Suggested short release-hardening plan

1. Fix auth first: real token auth and no passwords in `glows://` URLs.
2. Add settings validation and protocol-handler error paths for malformed configuration.
3. Add response-shape normalization helpers and guard track-info/pluginData access.
4. Fix or remove unsupported favorites URLs.
5. Improve scrobbling semantics after the above basics are stable.
