# Task: Add diagnostic toasts to setSpotifyVolumeViaWebApi in MainActivity.kt

**File to edit:** `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

Find the `setSpotifyVolumeViaWebApi` function. It currently looks like this:

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

Replace it with this version that adds diagnostic toasts:

```kotlin
private fun setSpotifyVolumeViaWebApi(vol: Int) {
    Thread {
        var token = prefs.getString("access_token", null)
        val expiresAt = prefs.getLong("expires_at", 0)
        if (token == null) {
            runOnUiThread {
                Toast.makeText(applicationContext, "SPV: no token, opening auth", Toast.LENGTH_SHORT).show()
                startSpotifyPkceAuth()
            }
            return@Thread
        }
        if (System.currentTimeMillis() > expiresAt - 60_000) {
            token = refreshSpotifyToken() ?: run {
                runOnUiThread {
                    Toast.makeText(applicationContext, "SPV: refresh failed, opening auth", Toast.LENGTH_SHORT).show()
                    startSpotifyPkceAuth()
                }
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
            runOnUiThread {
                Toast.makeText(applicationContext, "SPV: HTTP $status vol=$vol", Toast.LENGTH_SHORT).show()
            }
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
                val retryStatus = retry.responseCode
                runOnUiThread {
                    Toast.makeText(applicationContext, "SPV retry: HTTP $retryStatus", Toast.LENGTH_SHORT).show()
                }
            }
        } catch (e: Exception) {
            runOnUiThread {
                Toast.makeText(applicationContext, "SPV exception: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
    }.start()
}
```

No other changes.
