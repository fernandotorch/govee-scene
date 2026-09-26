# Task: Sync phase 0 — pull session logic out of the UI into a controller + renderer

**Goal:** a pure refactor, as groundwork for LAN sync. **The app must behave exactly as it does today, on both Android and Linux.** No new features, no UI changes visible to the user.

The session logic currently lives inside `_SessionPerformanceScreenState` in `lib/main.dart`: scene index, stop state, volumes, ducking, trigger playback and Spotify calls. Move it into two new classes:
- **`SessionController`**: the single source of truth for session state. It takes commands, updates state, and emits events. It must not touch audio, lights, Spotify or Flutter UI.
- **`SessionRenderer`**: listens to the controller's events and makes them happen on this device (lights via `SceneRunner`, audio via `AudioEngine`, Spotify via `SpotifyService`, including the ducking).

The screen becomes a view: it reads controller state, sends commands, and keeps only UI concerns (haptics, SnackBars, keyboard shortcuts, navigation, trigger border animation).

In phase 1, events will also go over the network, and each device's renderer will be switchable (lights on/off, sound on/off). Design with that in mind, but **do not build any networking now**.

Do not touch `android/`. Do not commit. Do not install the APK on any device.

---

## 1. New file `lib/session_controller.dart`

Move the data model classes (`SessionPack`, `SessionScene`, `SpotifyConfig`, `Trigger`, `AudioAsset`) from `main.dart` into a new `lib/session_model.dart`, unchanged. Import it from `main.dart` and from the new files.

### Events
A sealed class hierarchy, so it can later be serialised to JSON. Give each event `Map<String, dynamic> toJson()` and a `static SessionEvent fromJson(Map<String, dynamic>)` now; they are unused for the moment but needed in phase 1. The events:
- `SceneEntered(int index)`
- `TriggerFired(int index)`: the index within the current scene's triggers
- `StoppedAll()`
- `ResumedAll()`
- `SpotifyPauseToggled(bool paused)`
- `SpotifySeekRelative(int deltaMs)`
- `SpotifySkipped()`
- `AmbientVolumeChanged(double percent)`: 0–100
- `TriggerVolumeChanged(double percent)`: 0–100

### State
`SessionController extends ChangeNotifier`. Constructor: `SessionController(this.pack)`.
- `final SessionPack pack;`
- `int sceneIndex`
- `bool isStopped`
- `bool spotifyPaused`
- `double ambientVolume` (initialised by `enterScene` from `scene.ambientVolume`, as today)
- `double triggerVolume` (default 80, as today)
- `Map<int, ActiveTrigger> activeTriggers`
  - `ActiveTrigger`: `DateTime startedAt` and `Duration duration`.
  - The duration comes from `pack.audioManifest[t.soundId].durationMs`; if that is 0, use 5 s.
  - The controller removes the entry when the duration has elapsed (keep a `Timer` per index; cancel the old one if the same index fires again). It also clears them all on stop.
  - The UI draws the border progress from `startedAt` and `duration`, so a remote device can show progress without playing audio.
- `SessionScene get scene => pack.scenes[sceneIndex];`
- `Stream<SessionEvent> get events`: a broadcast `StreamController`.

### Commands
Each command updates state, calls `notifyListeners()`, then adds its event to the stream. Carry over the exact state logic from today's methods:
- `enterScene(int index)`
  - Sets `sceneIndex`, sets `ambientVolume` from the scene, sets `isStopped = false`.
  - If `scene.spotify.uri` is not empty, sets `spotifyPaused = false`.
  - Emits `SceneEntered`.
  - Do **not** clear `activeTriggers` on scene change. Today a ringing trigger keeps playing across the change; leave that as it is.
- `String? fireTrigger(int index)`
  - Validation that today shows SnackBars now returns an error string instead:
    - `'No sound or light assigned to this trigger'`
    - `'Sound not found: <id>'`
  - The UI shows the returned message as a SnackBar.
  - For a flash-only trigger (empty `soundId` with a `flashRef`), emit `TriggerFired` but do not add an `activeTriggers` entry. That matches today, where the border only shows for sound triggers.
  - For a sound trigger, add the `activeTriggers` entry and emit `TriggerFired`. Returns null on success.
- `toggleStopAll()`
  - Flips `isStopped`.
  - When stopping: set `spotifyPaused = true` and clear `activeTriggers` (cancelling their timers). Emit `StoppedAll`.
  - When resuming: if `scene.spotify.uri` is not empty, set `spotifyPaused = false`. Emit `ResumedAll`.
- `toggleSpotifyPause()`: flips `spotifyPaused` and emits `SpotifyPauseToggled`.
- `seekSpotify(int deltaMs)`: emits `SpotifySeekRelative`.
- `skipSpotify()`: emits `SpotifySkipped`.
- `setAmbientVolume(double percent)`: sets `ambientVolume` and emits `AmbientVolumeChanged`.
- `setTriggerVolume(double percent)`: sets `triggerVolume` and emits `TriggerVolumeChanged`.
- `dispose()`: cancels the timers and closes the stream.

## 2. New file `lib/session_renderer.dart`

`SessionRenderer(SessionController controller, SceneRunner runner, AudioEngine audio, SpotifyService spotify)`.
- It subscribes to `controller.events` and reads `controller` state (the current scene, `ambientVolume`, and so on) when it needs them.
- Add two public fields, `bool lightsEnabled = true;` and `bool soundEnabled = true;`.
  - Lights work only runs if `lightsEnabled`.
  - Audio and Spotify work only runs if `soundEnabled`.
  - Both stay true for now. Nothing sets them yet.
- **Move verbatim from the screen**, keeping every existing comment:
  - `_rampAmbient`, `_currentRampId`, `_ambientDuckFactor`, `_activeDucks`, `_duckGeneration`, `_duckAmbientFor` (including its `release()` logic, the generation guard, and the fallback timer).
  - `_performAmbientTransition`.
  - The side-effect halves of `_enterScene`, `_fireTrigger`, `_toggleStopAll`, `_toggleSpotify`, `_skipForward`, the Spotify skip, and both volume sliders.
  - Replace `if (!mounted) return;` checks with a `_disposed` flag.
- **Event handling:**
  - `SceneEntered`: `runner.setByRef(scene.goveeRef)`; Spotify play if a URI is set; `_performAmbientTransition(scene)`.
  - `TriggerFired`:
    - **Flash-only:** `runner.flash(flashRef)`.
    - **Sound:** if there is a `flashRef`, flash after 550 ms, as today. Then play through `audio.playTrigger` and call `_duckAmbientFor(player, asset.durationMs)`.
    - The renderer no longer handles `onDurationChanged` or the border animation; the controller's `ActiveTrigger` covers that.
    - Keep a try/catch around playback. On error, `debugPrint` it; there is no UI to show it in.
  - `StoppedAll` / `ResumedAll`: exactly today's `_toggleStopAll` side effects in each branch, including the await on `duckEnd` before `pause`.
  - `SpotifyPauseToggled`: pause or resume. `SpotifySeekRelative`: `spotify.seekRelative`. `SpotifySkipped`: `spotify.skip()`.
  - `AmbientVolumeChanged`: `audio.setAmbientVolume(v / 100)`. `TriggerVolumeChanged`: `audio.setTriggerVolume(v / 100)`.
- Add `void onAppResumed()`, which does what `didChangeAppLifecycleState(resumed)` does today: `spotify.connect()` and `runner.setByRef(current scene)`.
- `dispose()`: `spotify.pause()`, `runner.dispose()`, `audio.dispose()`, and cancel the subscription. This is the same teardown as today's screen `dispose`.
- **Ordering:** today, `_enterScene(0)` in `initState` both updates state and plays. The renderer must be subscribed **before** the first `enterScene(0)` command, or the first scene will not play.

## 3. `SessionPerformanceScreen` becomes a view

- **`initState`:** create `_controller = SessionController(widget.pack)`, then `_renderer = SessionRenderer(_controller, SceneRunner(widget.engine), AudioEngine(), SpotifyService.create())`, then `_controller.enterScene(0)`. Listen to `_controller` with `setState`.
- **Build:** read everything from `_controller` (scene, `isStopped`, `spotifyPaused`, volumes). Buttons call the commands.
  - Scene arrows call `enterScene`.
  - Trigger buttons: `HapticFeedback.lightImpact()`, then `final err = _controller.fireTrigger(i); if (err != null) showSnackBar(...)`.
  - The stop button and Space: `HapticFeedback.mediumImpact()`, then `toggleStopAll()`.
  - `forward_10`: `HapticFeedback.lightImpact()`, then `seekSpotify(10000)`.
  - The sliders call `setAmbientVolume` / `setTriggerVolume`.
- **Trigger border:**
  - Replace the per-trigger `AnimationController`s with a single `Ticker` (via `SingleTickerProviderStateMixin`, or keep the existing mixin). It runs only while `_controller.activeTriggers` is not empty, and calls `setState` on each tick.
  - Progress = `elapsed / duration`, clamped to 0..1. Pass that to the existing `_TriggerBorderPainter`.
  - Start and stop the ticker from the controller listener.
- **`didChangeAppLifecycleState(resumed)`:** `_renderer.onAppResumed()`.
- **`dispose`:** `_renderer.dispose()`, then `_controller.dispose()`, then the observer and ticker.
- Remove the old fields and methods that moved (`_audio`, `_runner`, `_spotify`, ducking, ramp, `_activeTriggers`, `_hasScene`, and so on).

## 4. Behaviour checklist — must still hold

- Entering a scene switches lights, starts Spotify at `startTime`, and cross-starts the ambient bed with a fade-in. If a trigger is still ringing, the fade-in goes only to the ducked level.
- A trigger ducks the ambient bed (×0.35) and Spotify (desktop volume API; Android audio focus). The duck lifts after the last overlapping trigger ends. In a scene without a bed, the bed stays silent after the duck ends.
- Stop: lights off, bed paused, triggers cut, the duck released (Spotify volume restored before the pause), Spotify paused. Resume: lights, bed fade-in, Spotify resumed if the scene has a URI.
- The ambient slider moves the live bed volume.
- Leaving the screen (✕, Esc, or system back) pauses Spotify and disposes audio and lights, as today.

## Verify
1. `flutter analyze`: no new issues. The pre-existing `_hasScene` warning should disappear.
2. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must succeed.
3. `flutter build apk --debug`: must succeed. Do not install it.

Report all three outputs, plus a short list of every field or method that moved and where it went.
