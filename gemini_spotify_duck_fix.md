# Task: Desktop Spotify ducking gets stuck low — make it race-proof

File: `lib/spotify_service.dart`, `DesktopSpotifyService` only. Do not touch `android/` or any other file. Do not commit. Do not install the APK.

## Bug
`duckStart()` reads the current volume with `GET /me/player` and saves it as `_preDuckVolume`, then lowers it. `duckEnd()` restores that saved value. Two failures:
1. **Race.** If `duckEnd()` runs while `duckStart()` is still waiting on the GET, `_preDuckVolume` is still null, so nothing is restored. `duckStart` then finishes and lowers the volume, and it stays low.
2. **Stale reads.** Spotify's `GET /me/player` reports volume several seconds late. When a second trigger fires shortly after the first one released, the GET still returns the *ducked* volume. That gets saved as the "normal" volume, so the next restore goes back to the low level. Each trigger ratchets the volume down.

## Fix: a small serialized state machine
- **Fields:**
  - `bool _wantDucked = false;` (what the caller asked for)
  - `bool _isDucked = false;` (what we last applied)
  - `int? _normalVolume;` (the user's un-ducked volume)
  - `int? _lastDuckedValue;`
  - `DateTime _lastVolumeWrite = DateTime.fromMillisecondsSinceEpoch(0);`
  - `Future<void> _duckChain = Future.value();`
- `duckStart()`: set `_wantDucked = true`, then `return _enqueue();`
- `duckEnd()`: set `_wantDucked = false`, then `return _enqueue();`
  - The returned future completes once this step has been applied. The stop-all path `await`s `duckEnd()` before pausing and relies on that.
- `_enqueue()`: `_duckChain = _duckChain.then((_) => _applyDuck()).catchError((_) {}); return _duckChain;` All duck work therefore runs strictly one step at a time, in order.
- **`_applyDuck()`:**
  - If `_wantDucked && !_isDucked`:
    1. Get the normal volume: `final v = await _readNormalVolume();`. If null, return (skip ducking).
    2. `_normalVolume = v`.
    3. `ducked = round(v * _spotifyDuckFactor)`.
    4. PUT the volume to `ducked`, then set `_lastDuckedValue = ducked`, `_isDucked = true`, `_lastVolumeWrite = now`.
  - Else if `!_wantDucked && _isDucked`:
    1. PUT the volume back to `_normalVolume`.
    2. Set `_isDucked = false`, `_lastVolumeWrite = now`.
  - Otherwise do nothing, because the state already matches.
- **`_readNormalVolume()`:**
  - If `_normalVolume != null` and less than 15 s have passed since `_lastVolumeWrite`, return the cached `_normalVolume`. Do not trust the API right after our own writes.
  - Otherwise `GET /me/player` and read `device.volume_percent`.
    - If it equals `_lastDuckedValue` and `_normalVolume != null`, treat the reading as stale and return `_normalVolume`.
    - Otherwise return the reading.
  - Return null on failure.
- Remove `_preDuckVolume` and the old duck code.
- Log each applied step: `SpotifyService: duck -> <v>%` and `SpotifyService: unduck -> <v>%`.

Verify:
- `flutter analyze`: no issues.
- `flutter test test/sync_smoke_test.dart` must still pass.
- `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.
