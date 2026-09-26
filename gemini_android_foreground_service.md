# Task: Android foreground service while hosting, so sessions survive screen-off and backgrounding

## Why
When a phone hosts a session (plays lights, audio and Spotify, and serves the LAN sync), Android throttles the app once the screen goes off or the app is backgrounded:
- the CPU sleeps, so Dart timers stop, the light animations freeze, and sync heartbeats die;
- Wi-Fi drops into power save.

The standard fix is a **foreground service** of type `mediaPlayback` (the host plays audio) that holds a partial wake lock and a Wi-Fi lock, and shows an ongoing notification.

You MAY edit `android/` for this task. **Do not change** any existing method in `MainActivity.kt` (the Spotify, multicast and hotspot code). Only add. Do not commit. Do not install the APK on any device.

## 1. Kotlin: `android/app/src/main/kotlin/com/feru/govee_scene/SessionService.kt`
- `class SessionService : Service()`.
- **`onStartCommand`:**
  - Read `EXTRA_TITLE` (the pack name) from the intent.
  - Create the notification channel `session` ("Session", `IMPORTANCE_LOW`, no sound) if needed.
  - Build an ongoing notification:
    - small icon: the app's existing launcher or monochrome icon; use `R.mipmap.ic_launcher` if nothing better exists;
    - title `Govee Scene`, text `Hosting · <title>`;
    - `setOngoing(true)`, `setSilent(true)`;
    - content intent: a `PendingIntent` (`FLAG_IMMUTABLE`) that brings `MainActivity` to the front (`FLAG_ACTIVITY_SINGLE_TOP`).
  - Call `startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)` on API 29+, and the 2-argument form below that. Use `ServiceCompat.startForeground` if androidx core is available.
  - Acquire the wake lock and Wi-Fi lock if they are not held yet:
    - `PowerManager.PARTIAL_WAKE_LOCK`, tag `govee_scene:session`, no timeout (it is released in `onDestroy`);
    - `WifiManager.createWifiLock(...)`: `WIFI_MODE_FULL_LOW_LATENCY` on API 29+, `WIFI_MODE_FULL_HIGH_PERF` below.
  - Return `START_NOT_STICKY`.
- **`onDestroy`:** release both locks if held, then call `stopForeground(STOP_FOREGROUND_REMOVE)`.
- `onBind` returns null.
- Companion helpers `start(context, title)` and `stop(context)`:
  - `start` uses `ContextCompat.startForegroundService`, and on a repeat call just updates the title.
  - `stop` uses `stopService`.

## 2. Manifest (`android/app/src/main/AndroidManifest.xml`)
- Add these permissions:
  - `android.permission.FOREGROUND_SERVICE`
  - `android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK`
  - `android.permission.WAKE_LOCK`
  - `android.permission.POST_NOTIFICATIONS`
- Declare the service inside `<application>`: `<service android:name=".SessionService" android:exported="false" android:foregroundServiceType="mediaPlayback" />`.
- Keep everything else unchanged.

## 3. MethodChannel (`MainActivity.kt`, same channel `com.feru.govee_scene/wifi`)
Add two new branches to the existing `when (call.method)`:
- `"startSessionService"`, with argument `title` (a String):
  - On API 33+, if `POST_NOTIFICATIONS` is not granted, call `ActivityCompat.requestPermissions(this, arrayOf(POST_NOTIFICATIONS), 1001)` **once**. Remember that it was asked in the existing SharedPreferences, so the user isn't nagged. The service must start either way, because a foreground service works without notification permission; the notification just isn't shown in the shade.
  - Then `SessionService.start(this, title)`, and `result.success(null)`.
  - Wrap it in try/catch and call `result.error(...)` on failure.
- `"stopSessionService"`: `SessionService.stop(this)`, then `result.success(null)`.

## 4. Dart
- In the **host lobby** (the stateful `SessionOverviewScreen` that owns the `SyncHost`):
  - After it starts hosting, on Android only, call `startSessionService` with `{'title': pack.name}`. Do this whether the `SyncHost` bind succeeded or failed, because a solo host still needs lights and audio kept alive.
  - In `dispose`, call `stopSessionService`.
  - Put both calls in try/catch and ignore errors.
- Change nothing for remote/client devices.

## 5. Dependencies
If `androidx.core` (ContextCompat, ServiceCompat, NotificationCompat, ActivityCompat) is not already on the classpath through Flutter, add `implementation("androidx.core:core-ktx:<a stable version compatible with the current compileSdk>")` to `android/app/build.gradle(.kts)`. Check first; Flutter usually brings it in.

## Verify
1. `flutter analyze`: no issues.
2. `flutter build apk --debug`: must succeed. Do not install it.
3. `flutter build linux --dart-define=SPOTIFY_CLIENT_ID=ca8e9bd0cc234c3d9e460224022db37f`: must still succeed.
4. `flutter test test/sync_smoke_test.dart`: must still pass.

Report all outputs and the exact list of files changed.
