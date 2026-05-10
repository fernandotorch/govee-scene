# Task: Add one diagnostic toast to setSpotifyVolume in MainActivity.kt

Find the `setSpotifyVolume` handler. It currently looks like this:

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

Replace only the `try` block inside the Thread with:

```kotlin
        try {
            val conn = webApiPut(
                "https://api.spotify.com/v1/me/player/volume?volume_percent=${vol.coerceIn(0, 100)}",
                token
            )
            val status = conn.responseCode
            val body = try { (conn.errorStream ?: conn.inputStream)?.bufferedReader()?.readText() } catch (_: Exception) { null }
            val msg = if (body != null) try { org.json.JSONObject(body).getJSONObject("error").getString("reason") } catch (_: Exception) { body } else "ok"
            runOnUiThread { Toast.makeText(applicationContext, "VOL $status $msg", Toast.LENGTH_SHORT).show() }
        } catch (e: Exception) {
            runOnUiThread { Toast.makeText(applicationContext, "VOL exc: ${e.message}", Toast.LENGTH_SHORT).show() }
        }
```

No other changes.
