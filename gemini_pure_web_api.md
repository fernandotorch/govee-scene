# Task: Replace Spotify App Remote SDK with pure Web API in MainActivity.kt

**File to edit:** `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

---

## Part 1 — Remove App Remote SDK

### 1a. Remove these imports
```kotlin
import com.spotify.android.appremote.api.ConnectionParams
import com.spotify.android.appremote.api.Connector
import com.spotify.android.appremote.api.SpotifyAppRemote
```

### 1b. Remove the class-level field
```kotlin
private var spotifyAppRemote: SpotifyAppRemote? = null
```

### 1c. Remove the onDestroy override entirely
```kotlin
override fun onDestroy() {
    SpotifyAppRemote.disconnect(spotifyAppRemote)
    super.onDestroy()
}
```

---

## Part 2 — Add helper functions

Add these two private functions to the class (before `configureFlutterEngine`):

### getValidToken
Returns a fresh access token, refreshing if needed. Returns null if no token exists (auth required). Must be called from a background thread.

```kotlin
private fun getValidToken(): String? {
    val token = prefs.getString("access_token", null) ?: return null
    val expiresAt = prefs.getLong("expires_at", 0)
    return if (System.currentTimeMillis() > expiresAt - 60_000) {
        refreshSpotifyToken()
    } else {
        token
    }
}
```

### webApiPut
Makes a PUT request to the Spotify Web API. If jsonBody is null, sends an empty body.

```kotlin
private fun webApiPut(url: String, token: String, jsonBody: String? = null): HttpURLConnection {
    val conn = URL(url).openConnection() as HttpURLConnection
    conn.requestMethod = "PUT"
    conn.setRequestProperty("Authorization", "Bearer $token")
    if (jsonBody != null) {
        conn.setRequestProperty("Content-Type", "application/json")
        conn.doOutput = true
        OutputStreamWriter(conn.outputStream).use { it.write(jsonBody) }
    } else {
        conn.setRequestProperty("Content-Length", "0")
        conn.doOutput = true
        conn.outputStream.close()
    }
    return conn
}
```

---

## Part 3 — Replace MethodChannel handlers

### setSpotifyVolume
Replace the existing `"setSpotifyVolume" ->` branch (whichever implementation it currently has) with:

```kotlin
"setSpotifyVolume" -> {
    val vol = (call.arguments as? Int) ?: (call.arguments as? Double)?.toInt() ?: 50
    Thread {
        val token = getValidToken() ?: run {
            runOnUiThread { startSpotifyPkceAuth() }
            runOnUiThread { result.success(null) }
            return@Thread
        }
        try {
            webApiPut(
                "https://api.spotify.com/v1/me/player/volume?volume_percent=${vol.coerceIn(0, 100)}",
                token
            ).responseCode
        } catch (_: Exception) {}
        runOnUiThread { result.success(null) }
    }.start()
}
```

### spotifyPlay
Replace the entire `"spotifyPlay" ->` branch (which currently contains App Remote SDK connection logic) with:

```kotlin
"spotifyPlay" -> {
    val uri = call.arguments as? String ?: run { result.success(null); return@setMethodCallHandler }
    val spotifyUri = toSpotifyUri(uri)
    Thread {
        val token = getValidToken() ?: run {
            runOnUiThread {
                startSpotifyPkceAuth()
                Toast.makeText(applicationContext, "Authorize Spotify then come back", Toast.LENGTH_LONG).show()
            }
            runOnUiThread { result.success(null) }
            return@Thread
        }
        try {
            val status = webApiPut(
                "https://api.spotify.com/v1/me/player/play",
                token,
                """{"context_uri":"$spotifyUri"}"""
            ).responseCode
            if (status == 404) {
                runOnUiThread {
                    Toast.makeText(applicationContext, "Open Spotify first, then enter the scene again", Toast.LENGTH_LONG).show()
                }
            }
        } catch (_: Exception) {}
        runOnUiThread { result.success(null) }
    }.start()
}
```

### spotifyPause
Replace the entire `"spotifyPause" ->` branch with:

```kotlin
"spotifyPause" -> {
    Thread {
        val token = getValidToken() ?: run { runOnUiThread { result.success(null) }; return@Thread }
        try { webApiPut("https://api.spotify.com/v1/me/player/pause", token).responseCode } catch (_: Exception) {}
        runOnUiThread { result.success(null) }
    }.start()
}
```

### spotifyResume
Replace the entire `"spotifyResume" ->` branch with:

```kotlin
"spotifyResume" -> {
    Thread {
        val token = getValidToken() ?: run { runOnUiThread { result.success(null) }; return@Thread }
        try { webApiPut("https://api.spotify.com/v1/me/player/play", token).responseCode } catch (_: Exception) {}
        runOnUiThread { result.success(null) }
    }.start()
}
```

---

## Part 4 — Remove debug SPV toasts

Remove every `Toast.makeText(...)` call whose message starts with `"SPV"`. There are several of these spread through the file from a debugging session. Do not remove any other toasts.

---

## Summary of what must NOT change
- `toSpotifyUri()` — keep it, still needed to normalise Spotify URLs
- `launchSpotifyUri` handler — keep it
- `setMediaVolume` handler — keep it
- `getHotspotIp`, `acquireMulticastLock`, `releaseMulticastLock` handlers — keep all of them
- All PKCE functions: `generateCodeVerifier`, `generateCodeChallenge`, `startSpotifyPkceAuth`, `exchangeSpotifyCode`, `refreshSpotifyToken`, `onNewIntent` — keep all of them
- `prefs`, `CLIENT_ID`, `REDIRECT_URI`, `PREFS_NAME` — keep all of them
