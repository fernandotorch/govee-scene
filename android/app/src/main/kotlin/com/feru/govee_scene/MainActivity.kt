package com.feru.govee_scene

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

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
                    else -> result.notImplemented()
                }
            }
    }
}
