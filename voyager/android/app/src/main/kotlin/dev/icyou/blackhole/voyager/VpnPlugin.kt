package dev.icyou.blackhole.voyager

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Build
import android.net.VpnService
import android.util.Base64
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.util.Timer
import java.util.TimerTask

class VpnPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware, PluginRegistry.ActivityResultListener {

    companion object {
        private const val TAG = "VpnPlugin"
        private const val VPN_REQUEST_CODE = 24601
        private var eventSink: EventChannel.EventSink? = null

        fun notifyStatusChanged() {
            val payload = BlackholeVpnService.instance?.getStatusPayload()
                ?: mapOf("status" to "disconnected")
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                eventSink?.success(payload)
            }
        }
    }

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingConfig: String? = null
    private var statusTimer: Timer? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, "com.blackhole.voyager/vpn").also {
            it.setMethodCallHandler(this)
        }
        eventChannel = EventChannel(binding.binaryMessenger, "com.blackhole.voyager/vpn_status").also {
            it.setStreamHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel?.setMethodCallHandler(null)
        eventChannel?.setStreamHandler(null)
        methodChannel = null
        eventChannel = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> {
                @Suppress("UNCHECKED_CAST")
                val args = call.arguments as? Map<String, Any>
                if (args == null) {
                    result.error("INVALID_ARGS", "Missing arguments", null)
                    return
                }
                startVpn(args, result)
            }
            "stop" -> {
                stopVpn()
                result.success(null)
            }
            "getStatus" -> {
                try {
                    val payload = BlackholeVpnService.instance?.getStatusPayload()
                        ?: mapOf("status" to "disconnected")
                    result.success(payload)
                } catch (t: Throwable) {
                    Log.e(TAG, "Failed to get VPN status", t)
                    result.success(
                        mapOf(
                            "status" to "error",
                            "error" to (t.message ?: "Failed to get VPN status"),
                        ),
                    )
                }
            }
            "generateKeypair" -> generateKeypair(result)
            "setActiveCandidate" -> setActiveCandidate(call, result)
            "fail" -> failTunnel(call, result)
            else -> result.notImplemented()
        }
    }

    private fun startVpn(args: Map<String, Any>, result: MethodChannel.Result) {
        val ctx = context ?: run {
            result.error("NO_CONTEXT", "No context available", null)
            return
        }

        val configJson = org.json.JSONObject(args).toString()

        // Check if VPN permission is needed
        val prepareIntent = VpnService.prepare(ctx)
        if (prepareIntent != null) {
            val act = activity
            if (act == null) {
                result.error("NO_ACTIVITY", "No activity for VPN consent", null)
                return
            }
            pendingResult = result
            pendingConfig = configJson
            act.startActivityForResult(prepareIntent, VPN_REQUEST_CODE)
            return
        }

        // Permission already granted
        try {
            launchVpnService(configJson)
            result.success(null)
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to launch VPN service", t)
            result.error(
                "VPN_START_FAILED",
                t.message ?: "Failed to launch VPN service",
                Log.getStackTraceString(t),
            )
        }
    }

    private fun launchVpnService(configJson: String) {
        val ctx = context ?: return
        val intent = Intent(ctx, BlackholeVpnService::class.java)
        intent.putExtra("config", configJson)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startForegroundService(intent)
        } else {
            ctx.startService(intent)
        }
    }

    private fun stopVpn() {
        BlackholeVpnService.instance?.stopTunnel(clearError = true)
        val ctx = context ?: return
        ctx.stopService(Intent(ctx, BlackholeVpnService::class.java))
    }

    private fun setActiveCandidate(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val addr = args?.get("addr") as? String
        val port = (args?.get("port") as? Number)?.toInt()
        if (addr.isNullOrEmpty() || port == null || port <= 0) {
            result.error("INVALID_ARGS", "setActiveCandidate requires addr and port", null)
            return
        }
        val service = BlackholeVpnService.instance
        if (service == null || !service.setActiveCandidate(addr, port)) {
            result.error("NO_VPN", "VPN is not running", null)
            return
        }
        result.success(null)
    }

    private fun failTunnel(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val message = args?.get("error") as? String ?: "WireGuard handshake timed out"
        val service = BlackholeVpnService.instance
        if (service == null) {
            result.success(null)
            return
        }
        service.failTunnel(message)
        result.success(null)
    }

    private fun generateKeypair(result: MethodChannel.Result) {
        try {
            val pubBytes = ByteArray(32)
            val privBytes = ByteArray(32)
            TunnelJni.bhWgGenerateKeypair(pubBytes, privBytes)
            result.success(
                mapOf(
                    "publicKey" to Base64.encodeToString(pubBytes, Base64.NO_WRAP),
                    "privateKey" to Base64.encodeToString(privBytes, Base64.NO_WRAP),
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to generate VPN keypair", t)
            result.error(
                "VPN_KEYPAIR_FAILED",
                t.message ?: "Failed to generate VPN keypair",
                Log.getStackTraceString(t),
            )
        }
    }

    // EventChannel.StreamHandler
    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        statusTimer = Timer().also { timer ->
            timer.scheduleAtFixedRate(object : TimerTask() {
                override fun run() { notifyStatusChanged() }
            }, 1000, 1000)
        }
    }

    override fun onCancel(arguments: Any?) {
        statusTimer?.cancel()
        statusTimer = null
        eventSink = null
    }

    // ActivityAware
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
    }
    override fun onDetachedFromActivity() { activity = null }

    // ActivityResultListener — handle VPN consent dialog result
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_REQUEST_CODE) return false

        val result = pendingResult
        val config = pendingConfig
        pendingResult = null
        pendingConfig = null

        if (resultCode == Activity.RESULT_OK && config != null) {
            try {
                launchVpnService(config)
                result?.success(null)
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to launch VPN service after consent", t)
                result?.error(
                    "VPN_START_FAILED",
                    t.message ?: "Failed to launch VPN service",
                    Log.getStackTraceString(t),
                )
            }
        } else {
            result?.error("VPN_DENIED", "User denied VPN permission", null)
        }
        return true
    }
}
