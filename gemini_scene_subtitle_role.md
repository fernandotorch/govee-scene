# Task: Show the role line and the effect line on both host and remote

In `lib/main.dart`, `SessionPerformanceScreen` build, under the scene name. Today it has:
```dart
if (widget.isRemote && widget.hostName != null)
  Text('Remote · ${widget.hostName}', ...)
else
  Text(scene.goveeRef, ...)
```
The remote therefore loses the `goveeRef` line. Change it so that **both modes show both lines**, in this order under the scene name:
1. `scene.goveeRef`, with the existing style (fontSize 10, `Color(0xFF63B8DE)`), exactly as the host shows it today.
2. A role line in grey (fontSize 10, `Colors.grey`):
   - Remote mode: `Remote · <host name>`.
   - Host mode: `Host · <this device's host name>`. Pass the host's name into the screen from the host lobby (`SyncHost.hostName`, or `SyncHost.defaultHostName()` if hosting failed). Add or reuse a `hostName` parameter so host mode also gets it.
   - If no name is available, omit the role line.

Change nothing else. Do not touch `android/`. Do not commit. Do not install the APK.

Verify:
- `flutter analyze`: no issues.
- `flutter test test/sync_smoke_test.dart` passes.
- `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f` succeeds.
- `flutter build apk --debug` succeeds. Do not install it.
