# Task: Sync phase 1a — three review fixes

Do not touch `android/`. Do not commit. Do not install the APK.

1. **Detect dead connections (heartbeat).**
   - Set `pingInterval = const Duration(seconds: 3)` on every WebSocket:
     - in `SyncHost._handleClient`, right after the upgrade, on the server-side socket;
     - in `SyncClient.connect`, right after `WebSocket.connect` succeeds, on the client socket.
   - Dart then closes a socket whose peer stops answering pings. That fires the existing `onDone` handlers, so the host drops vanished clients from the lobby list, and clients fire `onLost` ("Host lost") within a few seconds instead of minutes.
   - Check that nothing else needs changing for this to work.

2. **Host validates remote input.**
   - In `SyncHost._handleCommand`, for `enterScene`, ignore the command unless `0 <= index < c.pack.scenes.length`.
   - For `fireTrigger`, also ignore `index` values outside `0 <= index < c.scene.triggers.length`.
   - A bad message from a client must never throw on the host.
   - Wrap the whole body of `_handleCommand` in a try/catch that `debugPrint`s the error.

3. **Remote sliders respond immediately.**
   - In `RemoteSessionController.setAmbientVolume` / `setTriggerVolume`: set the local field and call `notifyListeners()` **before** `sendCommand`, so the slider follows the finger.
   - While the user is dragging, snapshots from the host must not yank the slider back:
     - Keep a `DateTime? _ambientLocalUntil` / `_triggerLocalUntil`, set to `now + 400 ms` on every local change.
     - In `applySnapshot`, skip overwriting that volume while `now` is before it.
   - Everything else in the remote controller stays host-authoritative, with no optimistic updates.

Verify:
1. `flutter analyze`: no issues.
2. `flutter test test/sync_smoke_test.dart` must pass.
3. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` must succeed.
4. `flutter build apk --debug` must succeed. Do not install it.
