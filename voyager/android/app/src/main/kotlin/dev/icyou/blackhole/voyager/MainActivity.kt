package dev.icyou.blackhole.voyager

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(VpnPlugin::class.java)) {
            flutterEngine.plugins.add(VpnPlugin())
        }
    }
}
