package com.defenseunicorns.peat_flutter_example

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // iroh local discovery (peat_mesh::discovery::MdnsDiscovery → swarm-discovery)
    // finds peers via raw UDP multicast on 224.0.0.251 / ff02::fb. Android's
    // Wi-Fi driver filters inbound multicast to save power unless an app holds a
    // WifiManager.MulticastLock (requires the CHANGE_WIFI_MULTICAST_STATE
    // permission, declared in the plugin manifest). Without this, two Android
    // devices cannot discover each other on the LAN — the same symptom as iOS
    // without the multicast entitlement. We hold the lock for the app's lifetime.
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("peat-mdns").apply {
            setReferenceCounted(true)
            acquire()
        }
    }

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }
}
