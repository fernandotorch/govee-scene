# Task: The trigger progress border must follow the real playback, not the manifest duration

## Bug
`SessionController.fireTrigger` times the border (`ActiveTrigger` plus its removal timer) from `pack.audioManifest[...].durationMs`, falling back to 5 s when that is 0. Many packs have 0 or stale durations, so the border keeps running after the sound has ended (and after the duck has lifted, since that follows `onPlayerComplete`).

## Fix: the host's renderer reports real playback back to the controller
Do not touch `android/`. Do not commit. Do not install the APK.

1. **`lib/session_controller.dart`:**
   - Give every fired sound trigger a unique `int playId`, from an incrementing counter. Store it in `ActiveTrigger` as a new field.
   - Add `playId` to the `TriggerFired` event, including its `toJson`/`fromJson`. Use `-1` for flash-only triggers.
   - Add two methods to `SessionController`. Neither is on `SessionControl` and neither is a network command; only the local renderer calls them.
     - `void updateTriggerDuration(int playId, Duration real)`:
       - Find the active trigger with that `playId`. If it is not there any more, do nothing.
       - Replace it with the same `startedAt` and the new `duration`.
       - Reset its removal timer to fire at `startedAt + real`. If that moment has already passed, remove the trigger now.
       - Call `notifyListeners()`.
     - `void endTrigger(int playId)`: if the active trigger at that index still has this `playId`, remove it, cancel its timer, and call `notifyListeners()`.
   - Keep the existing manifest-based duration and timer as the initial estimate and fallback.
2. **`lib/session_renderer.dart`**, in `_onTriggerFired`, after `final player = await audio.playTrigger(path);`:
   - `player.onDurationChanged.first.timeout(const Duration(seconds: 2))`. On a positive duration, call `controller.updateTriggerDuration(playId, d)`. Swallow timeouts and errors.
   - `player.onPlayerComplete.first.then((_) => controller.endTrigger(playId))`.
   - Leave the existing ducking calls unchanged.
   - The renderer needs the `playId` from the event. Get it from `TriggerFired`.
3. **Remote devices** get this automatically: the host's snapshot now carries the corrected `durationMs`, and the trigger disappears from `activeTriggers` when it ends. Check that `RemoteSessionController.applySnapshot` handles a changed duration for a trigger that is already active: it rebuilds from `elapsedMs`/`durationMs`, which should be fine. Confirm it.
4. **Update `test/sync_smoke_test.dart`:**
   - Add a unit test for `SessionController` alone.
   - Fire a trigger whose manifest duration is 5000 ms, then call `updateTriggerDuration(playId, 800ms)`. It must be gone after about 900 ms.
   - Fire again and call `endTrigger(playId)`. It must be gone immediately.
   - Calling `endTrigger` with an old `playId` after the same index has been re-fired must NOT remove the new one.

## Verify
- `flutter analyze`: no issues.
- `flutter test test/sync_smoke_test.dart`: all tests pass.
- `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.
- `flutter build apk --debug` must succeed. Do not install it.
