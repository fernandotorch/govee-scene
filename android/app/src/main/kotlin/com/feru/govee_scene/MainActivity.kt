package com.feru.govee_scene

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import android.widget.Toast
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    private val CLIENT_ID = "ca8e9bd0cc234c3d9e460224022db37f"
    private val REDIRECT_URI = "govee-scene://callback"
    private val PREFS_NAME = "spotify_tokens"

    private val prefs: SharedPreferences
        get() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun toSpotifyUri(input: String): String {
        if (input.startsWith("spotify:")) return input
        val match = Regex("open\\.spotify\\.com/([^/?]+)/([^?]+)").find(input)
        return if (match != null) "spotify:${match.groupValues[1]}:${match.groupValues[2]}" else input
    }

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
    }

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

            } catch (e: Exception) {
            }
        }.start()
    }

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
        } catch (e: Exception) {
            null
        }
    }

    private fun getValidToken(): String? {
        val token = prefs.getString("access_token", null) ?: return null
        val expiresAt = prefs.getLong("expires_at", 0)
        return if (System.currentTimeMillis() > expiresAt - 60_000) {
            refreshSpotifyToken()
        } else {
            token
        }
    }

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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.feru.govee_scene/wifi")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquireMulticastLock" -> {
                        val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wm.createMulticastLock("govee_scene")
                        multicastLock?.setReferenceCounted(false)
                        multicastLock?.acquire()
                        result.success(null)
                    }
                    "releaseMulticastLock" -> {
                        multicastLock?.release()
                        result.success(null)
                    }
                    "getHotspotIp" -> result.success(findHotspotIp())
                    "launchSpotifyUri" -> {
                        val uri = call.arguments as? String
                        if (uri != null) {
                            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).apply {
                                flags = Intent.FLAG_ACTIVITY_NEW_TASK
                            })
                        }
                        result.success(null)
                    }
                    "setMediaVolume" -> {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val vol = ((call.arguments as Int) / 100.0 * max).toInt().coerceIn(0, max)
                        am.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
                        result.success(null)
                    }
                    "setSpotifyVolume" -> {
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                        val vol = ((call.arguments as Int) / 100.0 * max).toInt().coerceIn(0, max)
                        am.setStreamVolume(AudioManager.STREAM_MUSIC, vol, 0)
                        result.success(null)
                    }
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
                    "spotifyPause" -> {
                        Thread {
                            val token = getValidToken() ?: run { runOnUiThread { result.success(null) }; return@Thread }
                            try { webApiPut("https://api.spotify.com/v1/me/player/pause", token).responseCode } catch (_: Exception) {}
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    "spotifyResume" -> {
                        Thread {
                            val token = getValidToken() ?: run { runOnUiThread { result.success(null) }; return@Thread }
                            try { webApiPut("https://api.spotify.com/v1/me/player/play", token).responseCode } catch (_: Exception) {}
                            runOnUiThread { result.success(null) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val data = intent.data ?: return
        if (data.scheme == "govee-scene" && data.host == "callback") {
            val code = data.getQueryParameter("code")
            if (code != null) {
                exchangeSpotifyCode(code)
            }
        }
    }

    private fun findHotspotIp(): String? {
        // Hotspot interface names vary by vendor: ap0 (most), wlan1 (Samsung/Xiaomi), swlan0 (Huawei).
        val hotspotPrefixes = listOf("ap", "swlan")
        val hotspotNames    = setOf("wlan1")
        // Interfaces to skip: loopback, mobile data, regular WiFi client, tun/vpn.
        val skipPrefixes    = listOf("lo", "rmnet", "ccmni", "v4-rmnet", "dummy", "wlan0", "tun", "p2p")

        return try {
            val ifaces = NetworkInterface.getNetworkInterfaces()?.toList() ?: return null

            fun ipv4(iface: NetworkInterface) = iface.inetAddresses.toList()
                .filterIsInstance<Inet4Address>()
                .firstOrNull { !it.isLoopbackAddress }
                ?.hostAddress

            // First pass: known hotspot interface names.
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name.lowercase()
                if (hotspotPrefixes.any { name.startsWith(it) } || name in hotspotNames)
                    return ipv4(iface) ?: continue
            }

            // Second pass: any active IPv4 not on a skip-listed interface.
            for (iface in ifaces) {
                if (!iface.isUp || iface.isLoopback) continue
                val name = iface.name.lowercase()
                if (skipPrefixes.any { name.startsWith(it) }) continue
                return ipv4(iface) ?: continue
            }
            null
        } catch (_: Exception) { null }
    }
}
