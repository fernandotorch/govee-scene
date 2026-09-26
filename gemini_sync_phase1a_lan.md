# Task: Sync phase 1a — LAN host/join, pack transfer, remote control

Read this whole file before starting. Phase 0 (commit 71624c6) split the session into `SessionController` (state and commands, emitting events) and `SessionRenderer` (lights, audio and Spotify on this device). This task connects devices on the same Wi-Fi.

## The model (decided by the product owner; do not change it)
- **The host plays everything** (lights, ambience, triggers, Spotify). Clients are pure remote controls. They never render anything, so they have no `SessionRenderer`.
- A device that loads a pack automatically **hosts** it. Alone, it behaves exactly like today.
- Other devices find hosts on the LAN, join, receive the pack from the host if they don't have it, and control the same session.
- Any device can change scene, fire triggers, stop/resume, use the Spotify controls, and move the sliders. **Every screen shows the same state.**
- Roles are fixed while a session runs. (Handing over the host role in the lobby comes in phase 1b. Do not build it now.)
- **If the host disappears, clients never take over.** They show "Host lost" and go back to the menu.

Constraints: no new pub packages. Use `dart:io` only (`HttpServer`, `WebSocketTransformer`, `WebSocket`, `RawDatagramSocket`). Do not touch `android/`. Do not commit. Do not install the APK on any device. Android single-device behaviour must stay identical.

---

## 1. Protocol — `lib/sync_protocol.dart`
- Constants:
  - `const int kSyncPort = 47810;` (TCP: HTTP and WebSocket)
  - `const int kDiscoveryPort = 47811;` (UDP)
  - `const int kProtocolVersion = 1;`
  - `const String kDiscoveryProbe = 'GOVEE_SCENE_DISCOVER';`
- Every message is a JSON object with a `"type"` field. Write small helpers to encode and decode them.
- **Client → host:**
  - `{"type":"hello","deviceId":"…","deviceName":"…","protocol":1}`
  - `{"type":"command","name":"<command>","args":{…}}`. The command names are: `enterScene {index}`, `fireTrigger {sceneIndex, index}`, `toggleStopAll {}`, `toggleSpotifyPause {}`, `seekSpotify {deltaMs}`, `skipSpotify {}`, `setAmbientVolume {percent}`, `setTriggerVolume {percent}`.
- **Host → client:**
  - `{"type":"welcome","hostName":"…","protocol":1,"pack":{"id":"<sha256 hex>","name":"…"} | null,"phase":"lobby"|"session","state":{…}|null}`
  - `{"type":"reject","reason":"…"}`, for example on a protocol mismatch: `"Different app version — update both devices"`.
  - `{"type":"lobby","devices":[{"id","name","isHost"}]}`, sent whenever a device connects or disconnects.
  - `{"type":"sessionStarted","state":{…}}`
  - `{"type":"state","state":{…}}`, a full snapshot, sent after every controller change.
  - `{"type":"sessionEnded"}`: the host left the performance screen. Clients go back to their lobby screen.
- **State snapshot**, `SessionController.toSnapshot()`, as JSON:
  ```json
  {"sceneIndex":0,"isStopped":false,"spotifyPaused":false,
   "ambientVolume":50,"triggerVolume":80,
   "activeTriggers":[{"index":2,"elapsedMs":1200,"durationMs":4000}]}
  ```
  Send elapsed time, not wall-clock time, so the clocks on the two devices do not need to agree.
- **Discovery:**
  - The client sends the UDP datagram `GOVEE_SCENE_DISCOVER` to port 47811.
  - The host answers the sender by unicast with JSON `{"name":"…","port":47810,"protocol":1,"pack":"<pack name or empty>"}`.
  - The client uses the **source address of the reply** as the host IP.

## 2. Pack identity and storage
- Refactor `extractAndLoadSession` into:
  - `Future<LoadedPack?> extractPack(Uint8List zipBytes)`, which does the extraction and parsing with no UI.
  - The existing UI wrapper, which shows the SnackBars and navigates.
- `LoadedPack` holds `SessionPack pack`, `Uint8List zipBytes` and `String id` (the SHA-256 hex of `zipBytes`, via the `crypto` package).
- Every path that loads a pack (stored sessions list, Studio download) goes through `extractPack`, then opens the overview/lobby with the `LoadedPack`.
- A client that receives a pack saves the ZIP into `packStorageDir()` as `<sanitised pack name>.zip`, so it also shows up under "Load Session" later. It then loads it with `extractPack`. If a stored ZIP with the same SHA-256 already exists there, it skips the download.

## 3. Host — `lib/sync_host.dart`, class `SyncHost`
- `SyncHost(LoadedPack loaded, String hostName)`. Methods: `start()`, `stop()`, `attachController(SessionController c)`, `detachController()`.
- **`start()`:**
  - Binds `HttpServer` on `InternetAddress.anyIPv4:kSyncPort` (`shared: false`).
  - Binds UDP `anyIPv4:kDiscoveryPort` (`reuseAddress: true`) and answers probes.
  - On Android, calls the existing `MethodChannel('com.feru.govee_scene/wifi')` method `acquireMulticastLock` (in a try/catch), because receiving broadcasts needs it. `stop()` calls `releaseMulticastLock`.
  - If a bind fails (for example, another host is already running on this machine), `start()` returns false, and the lobby shows "Could not host (port busy) — running solo".
- **HTTP routes:**
  - `GET /pack/<id>.zip` returns the ZIP bytes (`application/zip`, with a `Content-Length`). Any other id gets a 404.
  - `GET /sync` with a WebSocket upgrade handles clients.
- **Per client:**
  - Wait for `hello`. If the protocol differs, send `reject` and close.
  - Otherwise send `welcome` and add the client to the device list.
  - Broadcast `lobby` on every connect and disconnect.
  - Remember `request.connectionInfo.remoteAddress` for each client; phase 1b needs it.
- **Commands:**
  - If no controller is attached (lobby phase), ignore them.
  - Otherwise call the matching controller method.
  - `fireTrigger` is ignored if `args.sceneIndex != controller.sceneIndex`, so a trigger never plays in the wrong scene.
- **`attachController`:**
  - Broadcasts `sessionStarted`, then listens to the controller (`addListener`) and broadcasts a `state` snapshot on each change.
  - Coalesce the snapshots: at most one every 50 ms, always ending with the latest (use a trailing timer), so dragging a slider does not flood the network.
- **`detachController`:** removes the listener and broadcasts `sessionEnded`.
- **`stop()`:** closes every socket, the server and the UDP socket. The clients see the closed connection as "host lost".
- `hostName`: `Platform.localHostname`. If that is empty or `localhost`, use `'Android phone'` on Android and `'Computer'` elsewhere.

## 4. Client — `lib/sync_client.dart`
- **`SyncDiscovery`:**
  - `Stream<List<DiscoveredHost>>`, where `DiscoveredHost` has `address`, `port`, `name` and `packName`.
  - While active, every 2 s it sends the probe to `255.255.255.255` **and** to the directed broadcast of every non-loopback IPv4 interface (`NetworkInterface.list`; derive `a.b.c.255`, which is fine for /24 networks).
  - Set `broadcastEnabled = true` on the socket.
  - A host that has not answered for 6 s is dropped from the list.
  - Never list this device's own host. Compare the reply's address against this device's own interface addresses.
  - `start()` / `stop()`.
- **`SyncClient`:**
  - `connect(host)` opens `WebSocket.connect('ws://<ip>:<port>/sync')` with a 5 s timeout and sends `hello`.
  - It exposes the last `welcome`, the device list (as a `ValueNotifier`), and a stream of `sessionStarted`, `state` and `sessionEnded` messages.
  - `sendCommand(name, args)`.
  - `onLost` fires once when the socket closes or errors without us calling `close()`.
  - `downloadPack(id)` fetches `http://<ip>:<port>/pack/<id>.zip` with `HttpClient` and reports progress through a callback (use `Content-Length`).
- **`RemoteSessionController`:** a class with the **same public surface** that `SessionPerformanceScreen` uses today on `SessionController`: `pack`, `scene`, `sceneIndex`, `isStopped`, `spotifyPaused`, `ambientVolume`, `triggerVolume`, `activeTriggers`, and all the command methods.
  - Extract an abstract interface `SessionControl` (`implements Listenable` / `ChangeNotifier`) that both classes implement. Change the screen to depend on `SessionControl` instead of `SessionController`.
  - Commands validate locally in the same way (the same error strings for `fireTrigger`), then `sendCommand`.
  - It applies incoming snapshots to its fields, rebuilding `activeTriggers` with `startedAt = now - elapsedMs`, then calls `notifyListeners()`.
  - Do not update local state optimistically. Wait for the host's snapshot, so every device shows what the host actually did.
- **`TriggerFired`:** change the event to carry `sceneIndex` as well as the trigger index, including its `toJson`/`fromJson`. The renderer ignores the event if `sceneIndex != controller.sceneIndex`.

## 5. Screens (`lib/main.dart`, or new files under `lib/`)
- **Menu (`TheaterScreen`):**
  - Add a **"Nearby sessions"** section above "Load Session". It runs `SyncDiscovery` while the menu is the top route: stop it when another route is pushed, and restart it when that route pops.
  - Each discovered host shows as a card: `<host name> — <pack name>` with a **Join** button.
  - If none are found, show a single grey line: `No sessions on this network` with a small **Join by IP** text button. That opens a dialog with an IP field and connects to `<ip>:47810`. Remember the last-used IP in a small file in `getApplicationSupportDirectory()`.
- **Host lobby** (today's `SessionOverviewScreen`, made stateful and given the `LoadedPack`):
  - On open, create and start a `SyncHost`. Stop it on dispose.
  - Show a line under the pack title:
    - `Hosting · 0 devices connected`, or `Hosting · Phone, Feru-laptop connected`, from the lobby list.
    - If `start()` failed: `Could not host (port busy) — running solo`.
  - Tapping the start card pushes `SessionPerformanceScreen` in host mode:
    - It creates the `SessionController` and `SessionRenderer` exactly as today.
    - It then calls `host.attachController(controller)`, and `host.detachController()` in dispose.
  - Everything else on that screen stays as it is.
- **Client lobby** (new `ClientLobbyScreen`):
  - Connects to the host.
  - On `reject`, shows the reason and pops back to the menu.
  - On `welcome` with a pack:
    - If the pack is not stored locally (matched by SHA-256), downloads it with a progress bar (`Receiving pack… 43%`).
    - Then extracts it with `extractPack`.
  - Shows the pack name and `Connected to <host> · waiting for host to start`, plus the device list.
  - On `sessionStarted`, or if `welcome.phase == "session"`: pushes `SessionPerformanceScreen` in **remote mode**, with a `RemoteSessionController`, no renderer, and no Spotify/audio/lights objects.
  - On `sessionEnded`: pops back to the client lobby.
  - On `onLost`, at any point: pops back to the menu and shows the SnackBar `Host lost — session ended on this device`.
  - The back or ✕ button closes the client cleanly.
- **`SessionPerformanceScreen`:**
  - Accepts either mode. Keep one screen: pass a `SessionControl` plus an optional `SessionRenderer`.
  - Remote mode shows a small grey label `Remote · <host name>` under the scene name.
  - Leaving the screen in remote mode only closes the screen. It must not send stop or pause commands.

## 6. Unchanged behaviour to preserve
- A single device with no other devices around works exactly as before: host mode with nobody connected.
- Ducking, stop/resume, Spotify and lights all live only in the host's renderer.

## Verify
1. `flutter analyze`: no new issues.
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.
3. `flutter build apk --debug`: must succeed. Do not install it.
4. **Local loopback smoke test (Linux).** Write a small Dart script under `tool/sync_smoke_test.dart` that:
   - starts a `SyncHost` with a tiny in-memory test pack: build a ZIP with the `archive` package, holding a `session.json` with 2 scenes and 1 trigger (reuse the `SessionPack` JSON shape);
   - connects a `SyncClient` to `127.0.0.1`;
   - checks that `welcome` arrives with the right pack id;
   - downloads the pack and compares its SHA-256;
   - attaches a `SessionController`, then sends `enterScene {index:1}` from the client, and checks that the client receives a `state` with `sceneIndex == 1`.

   Run it with `dart run tool/sync_smoke_test.dart` if the classes can run without Flutter bindings. If they cannot (because of `flutter/foundation` imports), put the same test under `test/sync_smoke_test.dart` and run `flutter test test/sync_smoke_test.dart` instead. Report the result.

Report all outputs, and a list of the new files and classes.
