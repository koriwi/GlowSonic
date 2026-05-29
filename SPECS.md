# GlowSonic development notes

GlowSonic is a Subsonic/OpenSubsonic client plugin for Lyrion Music Server.

## Notes

- Navidrome and other OpenSubsonic servers use string IDs; never cast IDs to integers.
- UI and browsing calls should use `Slim::Networking::SimpleAsyncHTTP`.
- Playback uses `glows://` URLs and delegates streaming to LMS HTTP/HTTPS handlers.
- `getCoverArt` must be requested without `f=json` so the server returns image bytes.
- Navidrome marks tracks as played via `scrobble` with `submission=true`, not via `stream`.

## Main files

- `Plugin.pm` — LMS entry point, OPML menus, search, scrobbling
- `API.pm` — shared Subsonic URL/auth helpers
- `API/Async.pm` — async API client for browsing
- `API/Sync.pm` — blocking API client for settings/tests
- `ProtocolHandler.pm` — playback and playlist expansion
- `Settings.pm` — LMS settings page
