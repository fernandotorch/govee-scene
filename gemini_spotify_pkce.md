# Task: Replace `setSpotifyVolume` with Spotify Web API (PKCE)

**File to edit:** `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

**No other files need to change.**

---

## Context

The app controls Govee lights and plays Spotify + ambient audio during TTRPG sessions.
Spotify playback is controlled via the Spotify App Remote SDK (already working).
The ambient audio uses `audioplayers` via Flutter.

**The problem:** `setSpotifyVolume` currently calls `AudioManager.setStreamVolume(STREAM_MUSIC)`,
which is the shared system audio stream — so moving the Spotify slider also changes ambient volume.

**The fix:** Replace `setSpotifyVolume` to use the Spotify Web API endpoint
`PUT https://api.spotify.com/v1/me/player/volume?volume_percent={vol}`,
which controls only Spotify's own playback volume independently of system audio.

**Auth method:** PKCE (no client secret needed). The `govee-scene://callback` deep link
is already registered in the Spotify Developer Dashboard and already has an intent filter
in `AndroidManifest.xml`. `android:launchMode="singleTop"` is set, so `onNewIntent` fires
correctly when the browser redirects back.

---

## What to implement

### 1. New imports (add at top of file)

```kotlin
import android.content.SharedPreferences
import android.security.keystore.KeyProperties
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import org.json.JSONObject
```

### 2. Constants (inside `MainActivity` class, at class level)

```kotlin
private val CLIENT_ID = "ca8e9bd0cc234c3d9e460224022db37f"
private val REDIRECT_URI = "govee-scene://callback"
private val PREFS_NAME = "spotify_tokens"
```

### 3. Helper: SharedPreferences accessor

```kotlin
private val prefs: SharedPreferences
    get() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
```

### 4. PKCE helpers

```kotlin
private fun generateCodeVerifier(): String {
    val bytes = ByteArray(96)
    SecureRandom().nextBytes(bytes)
    return android.util.Base64.encodeToString(bytes,
        android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)
        .take(128)
}

private fun generateCodeChallenge(verifier: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.US_ASCII))
    return android.util.Base64.encodeToString(digest,
        android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP)
}
```

### 5. Start PKCE auth flow

```kotlin
private fun startSpotifyPkceAuth() {
    val verifier = generateCodeVerifier()
    val challenge = generateCodeChallenge(verifier)
    prefs.edit().putString("code_verifier", verifier).apply()
    val authUrl = "https://accounts.spotify.com/authorize" +
        "?client_id=$CLIENT_ID" +
        "&response_type=code" +
        "&redirect_uri=${Uri.encode(REDIRECT_URI)}" +
        "&code_challenge_method=S256" +
        "&code_challenge=$challenge" +
        "&scope=user-modify-playback-state"
    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authUrl)).apply {
        flags = Intent.FLAG_ACTIVITY_NEW_TASK
    })
    Toast.makeText(applicationContext, "Authorize Spotify volume in browser, then come back", Toast.LENGTH_LONG).show()
}
```

### 6. Token exchange (called from `onNewIntent`)

Run the HTTP call on a background thread. Store results in SharedPreferences.

```kotlin
private fun exchangeSpotifyCode(code: String) {
    val verifier = prefs.getString("code_verifier", null) ?: return
    Thread {
        try {
            val conn = URL("https://accounts.spotify.com/api/token").openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
            conn.doOutput = true
            val body = "grant_type=authorization_code" +
                "&code=$code" +
                "&redirect_uri=${Uri.encode(REDIRECT_URI)}" +
                "&client_id=$CLIENT_ID" +
                "&code_verifier=$verifier"
            OutputStreamWriter(conn.outputStream).use { it.write(body) }
            val response = conn.inputStream.bufferedReader().readText()
            val json = JSONObject(response)
            val expiresAt = System.currentTimeMillis() + json.getLong("expires_in") * 1000
            prefs.edit()
                .putString("access_token", json.getString("access_token"))
                .putString("refresh_token", json.optString("refresh_token"))
                .putLong("expires_at", expiresAt)
                .remove("code_verifier")
                .apply()
            runOnUiThread {
                Toast.makeText(applicationContext, "Spotify volume control ready", Toast.LENGTH_SHORT).show()
            }
        } catch (e: Exception) {
            runOnUiThread {
                Toast.makeText(applicationContext, "Token exchange failed: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
    }.start()
}
```

### 7. Token refresh

```kotlin
private fun refreshSpotifyToken(): String? {
    val refreshToken = prefs.getString("refresh_token", null) ?: return null
    return try {
        val conn = URL("https://accounts.spotify.com/api/token").openConnection() as HttpURLConnection
        conn.requestMethod = "POST"
        conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        conn.doOutput = true
        val body = "grant_type=refresh_token" +
            "&refresh_token=$refreshToken" +
            "&client_id=$CLIENT_ID"
        OutputStreamWriter(conn.outputStream).use { it.write(body) }
        val response = conn.inputStream.bufferedReader().readText()
        val json = JSONObject(response)
        val expiresAt = System.currentTimeMillis() + json.getLong("expires_in") * 1000
        val newAccess = json.getString("access_token")
        val newRefresh = json.optString("refresh_token").takeIf { it.isNotEmpty() } ?: refreshToken
        prefs.edit()
            .putString("access_token", newAccess)
            .putString("refresh_token", newRefresh)
            .putLong("expires_at", expiresAt)
            .apply()
        newAccess
    } catch (e: Exception) { null }
}
```

### 8. Set Spotify volume via Web API

```kotlin
private fun setSpotifyVolumeViaWebApi(vol: Int) {
    Thread {
        // Get or refresh access token
        var token = prefs.getString("access_token", null)
        val expiresAt = prefs.getLong("expires_at", 0)
        if (token == null) {
            runOnUiThread { startSpotifyPkceAuth() }
            return@Thread
        }
        if (System.currentTimeMillis() > expiresAt - 60_000) {
            token = refreshSpotifyToken() ?: run {
                runOnUiThread { startSpotifyPkceAuth() }
                return@Thread
            }
        }
        try {
            val conn = URL("https://api.spotify.com/v1/me/player/volume?volume_percent=$vol")
                .openConnection() as HttpURLConnection
            conn.requestMethod = "PUT"
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Content-Length", "0")
            conn.doOutput = true
            conn.outputStream.close()
            val status = conn.responseCode
            if (status == 401) {
                val fresh = refreshSpotifyToken() ?: run {
                    runOnUiThread { startSpotifyPkceAuth() }
                    return@Thread
                }
                val retry = URL("https://api.spotify.com/v1/me/player/volume?volume_percent=$vol")
                    .openConnection() as HttpURLConnection
                retry.requestMethod = "PUT"
                retry.setRequestProperty("Authorization", "Bearer $fresh")
                retry.setRequestProperty("Content-Length", "0")
                retry.doOutput = true
                retry.outputStream.close()
                retry.responseCode
            }
        } catch (_: Exception) {}
    }.start()
}
```

### 9. Override `onNewIntent` to catch the PKCE callback

Add this override to `MainActivity`:

```kotlin
override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    val data = intent.data ?: return
    if (data.scheme == "govee-scene" && data.host == "callback") {
        val code = data.getQueryParameter("code") ?: return
        exchangeSpotifyCode(code)
    }
}
```

### 10. Update the `setSpotifyVolume` MethodChannel handler

**Find this existing block** (lines ~61-67):

```kotlin
"setSpotifyVolume" -> {
    val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
    val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
    val vol = ((call.arguments as Int) / 100.0 * max).toInt().coerceIn(0, max)
    am.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
    result.success(null)
}
```

**Replace it with:**

```kotlin
"setSpotifyVolume" -> {
    val vol = (call.arguments as? Int) ?: (call.arguments as? Double)?.toInt() ?: 50
    setSpotifyVolumeViaWebApi(vol.coerceIn(0, 100))
    result.success(null)
}
```

Note: `call.arguments` may arrive as `Int` or `Double` depending on how Dart sends it — handle both.

---

## What does NOT change

- `setMediaVolume` handler — leave it alone (used elsewhere)
- `main.dart` — no changes needed; the slider already calls `setSpotifyVolume`
- `pubspec.yaml` — no new dependencies; HTTP is done via Java stdlib in Kotlin
- `AndroidManifest.xml` — already has the deep link intent filter and INTERNET permission

---

## Expected behaviour after the change

1. First use: slider fires `setSpotifyVolume` → no token → browser opens Spotify auth page → user approves → browser redirects to `govee-scene://callback?code=...` → `onNewIntent` fires → token exchange → toast "Spotify volume control ready".
2. Subsequent uses: slider fires `setSpotifyVolume` → token valid → Web API call → Spotify volume changes independently of ambient audio.
3. Token expired: auto-refresh, transparent to user.
4. Refresh token invalid: re-triggers auth flow.
