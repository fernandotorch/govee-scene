package com.feru.govee_scene

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface
import com.spotify.android.appremote.api.ConnectionParams
import com.spotify.android.appremote.api.Connector
import com.spotify.android.appremote.api.SpotifyAppRemote
import android.widget.Toast

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var spotifyAppRemote: SpotifyAppRemote? = null

    private fun toSpotifyUri(input: String): String {
        if (input.startsWith("spotify:")) return input
        val match = Regex("open\\.spotify\\.com/([^/?]+)/([^?]+)").find(input)
        return if (match != null) "spotify:${match.groupValues[1]}:${match.groupValues[2]}" else input
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
                        Toast.makeText(applicationContext, "[1] spotifyPlay: $spotifyUri", Toast.LENGTH_LONG).show()
                        val existing = spotifyAppRemote
                        if (existing != null && existing.isConnected) {
                            Toast.makeText(applicationContext, "[2] reusing connection", Toast.LENGTH_SHORT).show()
                            existing.playerApi.play(spotifyUri)
                                .setResultCallback { result.success(null) }
                                .setErrorCallback { err ->
                                    Toast.makeText(applicationContext, "Play error: ${err.message}", Toast.LENGTH_LONG).show()
                                    result.success(null)
                                }
                            return@setMethodCallHandler
                        }
                        Toast.makeText(applicationContext, "[3] connecting to Spotify...", Toast.LENGTH_LONG).show()
                        val params = ConnectionParams.Builder("ca8e9bd0cc234c3d9e460224022db37f")
                            .setRedirectUri("govee-scene://callback")
                            .showAuthView(false)
                            .build()
                        SpotifyAppRemote.connect(this@MainActivity, params, object : Connector.ConnectionListener {
                            override fun onConnected(appRemote: SpotifyAppRemote) {
                                spotifyAppRemote = appRemote
                                Toast.makeText(applicationContext, "[4] connected, playing", Toast.LENGTH_SHORT).show()
                                appRemote.playerApi.play(spotifyUri)
                                    .setResultCallback { result.success(null) }
                                    .setErrorCallback { err ->
                                        Toast.makeText(applicationContext, "Play error: ${err.message}", Toast.LENGTH_LONG).show()
                                        result.success(null)
                                    }
                            }
                            override fun onFailure(throwable: Throwable) {
                                if (throwable.message?.contains("authorization", ignoreCase = true) == true) {
                                    Toast.makeText(applicationContext, "Spotify auth needed — approving in browser. Come back and trigger scene again.", Toast.LENGTH_LONG).show()
                                    val authUrl = "https://accounts.spotify.com/authorize" +
                                        "?client_id=ca8e9bd0cc234c3d9e460224022db37f" +
                                        "&response_type=code" +
                                        "&redirect_uri=govee-scene%3A%2F%2Fcallback" +
                                        "&scope=app-remote-control"
                                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authUrl)))
                                } else {
                                    Toast.makeText(applicationContext, "FAIL: ${throwable.javaClass.simpleName}: ${throwable.message}", Toast.LENGTH_LONG).show()
                                }
                                result.success(null)
                            }
                        })
                    }
                    "spotifyPause" -> {
                        spotifyAppRemote?.playerApi?.pause()
                        result.success(null)
                    }
                    "spotifyResume" -> {
                        spotifyAppRemote?.playerApi?.resume()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        SpotifyAppRemote.disconnect(spotifyAppRemote)
        super.onDestroy()
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
