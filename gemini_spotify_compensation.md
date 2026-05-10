# Task: Replace Web API volume with AudioManager + ambient compensation

Two files to edit: `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt` and `lib/main.dart`.

---

## Part 1 — MainActivity.kt

### 1a. Remove all PKCE/Web API additions

Remove the following private fields and functions entirely:
- `private val CLIENT_ID`
- `private val REDIRECT_URI`
- `private val PREFS_NAME`
- `private val prefs: SharedPreferences`
- `fun generateCodeVerifier()`
- `fun generateCodeChallenge(verifier)`
- `fun startSpotifyPkceAuth()`
- `fun exchangeSpotifyCode(code)`
- `fun refreshSpotifyToken()`
- `fun setSpotifyVolumeViaWebApi(vol)`
- `override fun onNewIntent(intent)`

Remove these imports that are no longer needed:
- `import android.content.SharedPreferences`
- `import java.io.OutputStreamWriter`
- `import java.net.HttpURLConnection`
- `import java.net.URL`
- `import java.security.MessageDigest`
- `import java.security.SecureRandom`
- `import org.json.JSONObject`

### 1b. Restore setSpotifyVolume handler to AudioManager

Find the `setSpotifyVolume` handler. It currently calls `setSpotifyVolumeViaWebApi`. Replace the entire `"setSpotifyVolume" ->` branch with:

```kotlin
"setSpotifyVolume" -> {
    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    val vol = ((call.arguments as Int) / 100.0 * max).toInt().coerceIn(0, max)
    am.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
    result.success(null)
}
```

### 1c. Remove all debug "SPV:" toasts

Remove every `Toast.makeText(...)` call whose message starts with `"SPV"` — there are several added during debugging. Do not remove any other toasts.

---

## Part 2 — lib/main.dart

### 2a. Add ambient compensation when Spotify slider changes

Find this Slider inside the "Live Mixer" section of `_SessionPerformanceScreenState.build()`:

```dart
Row(children: [
  const Icon(Icons.music_note, size: 18, color: Colors.grey),
  Expanded(child: Slider(
    value: _spotifyVol, min: 0, max: 100, activeColor: const Color(0xFF63B8DE),
    onChanged: (v) {
      setState(() => _spotifyVol = v);
      _wifiChannel.invokeMethod('setSpotifyVolume', v.round()).catchError((_) {});
    },
  )),
```

Replace the `onChanged` lambda only — keep the Slider widget wrapper unchanged:

```dart
    onChanged: (v) {
      if (_spotifyVol > 0 && v > 0) {
        final compensated = (_ambientVol * _spotifyVol / v).clamp(0.0, 100.0);
        setState(() { _spotifyVol = v; _ambientVol = compensated; });
        _audio.setAmbientVolume(compensated / 100.0);
      } else {
        setState(() => _spotifyVol = v);
      }
      _wifiChannel.invokeMethod('setSpotifyVolume', v.round()).catchError((_) {});
    },
```

No other changes to main.dart.
