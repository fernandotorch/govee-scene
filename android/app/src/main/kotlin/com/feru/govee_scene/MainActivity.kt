package com.feru.govee_scene

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

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
                    else -> result.notImplemented()
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
