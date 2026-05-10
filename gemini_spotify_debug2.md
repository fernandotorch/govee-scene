# Task: Read Spotify error body on non-204 responses in setSpotifyVolumeViaWebApi

**File to edit:** `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

Find the `try` block inside `setSpotifyVolumeViaWebApi`. It currently looks like this:

```kotlin
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
```

Replace only this `try` block with the following, which reads the error body on non-204 responses:

```kotlin
        try {
            val conn = URL("https://api.spotify.com/v1/me/player/volume?volume_percent=$vol")
                .openConnection() as HttpURLConnection
            conn.requestMethod = "PUT"
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.setRequestProperty("Content-Length", "0")
            conn.doOutput = true
            conn.outputStream.close()
            val status = conn.responseCode
            if (status == 204) {
                runOnUiThread {
                    Toast.makeText(applicationContext, "SPV: OK vol=$vol", Toast.LENGTH_SHORT).show()
                }
            } else {
                val errorBody = try {
                    (conn.errorStream ?: conn.inputStream).bufferedReader().readText()
                } catch (_: Exception) { "(no body)" }
                runOnUiThread {
                    Toast.makeText(applicationContext, "SPV $status: $errorBody", Toast.LENGTH_LONG).show()
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
                    val retryBody = try {
                        (retry.errorStream ?: retry.inputStream).bufferedReader().readText()
                    } catch (_: Exception) { "(no body)" }
                    runOnUiThread {
                        Toast.makeText(applicationContext, "SPV retry $retryStatus: $retryBody", Toast.LENGTH_LONG).show()
                    }
                }
            }
        } catch (e: Exception) {
            runOnUiThread {
                Toast.makeText(applicationContext, "SPV exception: ${e.message}", Toast.LENGTH_LONG).show()
            }
        }
```

No other changes.
