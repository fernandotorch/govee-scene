# Task: Parse Spotify error JSON and log it in MainActivity.kt

**File to edit:** `android/app/src/main/kotlin/com/feru/govee_scene/MainActivity.kt`

Find this block inside `setSpotifyVolumeViaWebApi`:

```kotlin
                    val errorBody = try {
                        (conn.errorStream ?: conn.inputStream).bufferedReader().readText()
                    } catch (_: Exception) { "(no body)" }
                    runOnUiThread {
                        Toast.makeText(applicationContext, "SPV $status: $errorBody", Toast.LENGTH_LONG).show()
                    }
```

Replace it with:

```kotlin
                    val errorBody = try {
                        (conn.errorStream ?: conn.inputStream).bufferedReader().readText()
                    } catch (_: Exception) { "(no body)" }
                    val errorMsg = try {
                        JSONObject(errorBody).getJSONObject("error").getString("message")
                    } catch (_: Exception) { errorBody }
                    android.util.Log.e("SPV", "HTTP $status body=$errorBody")
                    runOnUiThread {
                        Toast.makeText(applicationContext, "SPV $status: $errorMsg", Toast.LENGTH_LONG).show()
                    }
```

No other changes.
