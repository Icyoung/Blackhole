package dev.icyou.blackhole.voyager

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

class BlackholeVpnService : VpnService() {

    companion object {
        private const val TAG = "BlackholeVPN"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "vpn_service"
        private const val HANDSHAKE_TOTAL_BUDGET_MS = 30_000L

        @Volatile var instance: BlackholeVpnService? = null
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var tunOutput: FileOutputStream? = null
    private val tunnelHandle = AtomicLong(0)
    private var udpSocket: DatagramSocket? = null
    private val destLock = Any()
    @Volatile private var peerAddress: InetSocketAddress? = null
    private val isActive = AtomicBoolean(false)
    private var activeConfig: JSONObject? = null
    @Volatile private var lastError: String? = null
    @Volatile private var startedAtElapsedMs: Long = 0L
    @Volatile private var announcedConnected = false
    @Volatile private var pendingNetcheckNonce: String? = null
    @Volatile private var observedCandidates: JSONArray? = null

    val tunPacketsOut = AtomicLong(0)
    val tunPacketsIn = AtomicLong(0)
    val udpPacketsOut = AtomicLong(0)
    val udpPacketsIn = AtomicLong(0)

    private var tunReadThread: Thread? = null
    private var udpReadThread: Thread? = null
    private val scheduler = Executors.newSingleThreadScheduledExecutor()
    private var timerFuture: ScheduledFuture<*>? = null
    private val wgLock = Any()

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val configJson = intent?.getStringExtra("config")
        if (configJson == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification("Connecting..."))

        try {
            startTunnel(JSONObject(configJson))
        } catch (t: Throwable) {
            recordFatalError("Failed to start tunnel", t)
        }

        return START_NOT_STICKY
    }

    private fun startTunnel(config: JSONObject) {
        if (isActive.get()) stopTunnel()
        lastError = null

        val privateKey = config.getString("privateKey")
        val peerPublicKey = config.getString("peerPublicKey")
        val serverAddr = config.getString("serverAddr")
        val serverPort = config.getInt("serverPort")
        val clientIp = config.optString("clientIp", "10.13.37.2")
        val subnet = config.optString("subnet", "10.13.37.0/24")
        val mtu = config.optInt("mtu", 1280)

        activeConfig = config
        tunPacketsOut.set(0)
        tunPacketsIn.set(0)
        udpPacketsOut.set(0)
        udpPacketsIn.set(0)
        announcedConnected = false
        observedCandidates = null
        pendingNetcheckNonce = null
        startedAtElapsedMs = SystemClock.elapsedRealtime()

        // 1. Create WG tunnel handle
        val wgConfig = JSONObject().apply {
            put("private_key", privateKey)
            put("peer_public_key", peerPublicKey)
            if (config.has("presharedKey")) put("preshared_key", config.getString("presharedKey"))
            if (config.has("keepaliveSecs")) put("keepalive_secs", config.getInt("keepaliveSecs"))
        }
        val handle = TunnelJni.bhWgTunnelNew(wgConfig.toString())
        if (handle == 0L) {
            throw RuntimeException("Failed to create WG tunnel")
        }
        tunnelHandle.set(handle)
        Log.i(TAG, "WG tunnel created")

        // 2. Bind one unconnected UDP socket and protect it before any send.
        val localPort = config.optInt("localPort", 0)
        val socket = DatagramSocket(null)
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(localPort))
        if (!protect(socket)) {
            socket.close()
            throw RuntimeException("Failed to protect VPN UDP socket")
        }
        udpSocket = socket
        synchronized(destLock) {
            peerAddress = InetSocketAddress(serverAddr, serverPort)
        }
        Log.i(TAG, "UDP bound localPort=${socket.localPort} dest=$serverAddr:$serverPort")

        // 3. Create TUN interface
        val prefixLen = subnet.substringAfter("/", "24").toInt()
        val builder = Builder()
            .setSession("Blackhole VPN")
            .setMtu(mtu)
            .addAddress(clientIp, prefixLen)

        val subnetAddr = subnet.substringBefore("/")
        builder.addRoute(subnetAddr, prefixLen)

        val routes = config.optJSONArray("internalRoutes")
        if (routes != null) {
            for (i in 0 until routes.length()) {
                val route = routes.getString(i)
                val addr = route.substringBefore("/")
                val prefix = route.substringAfter("/", "32").toInt()
                builder.addRoute(addr, prefix)
            }
        }

        val dns = config.optJSONArray("dns")
        if (dns != null) {
            for (i in 0 until dns.length()) {
                builder.addDnsServer(dns.getString(i))
            }
        }

        val fd = builder.establish() ?: throw RuntimeException("VPN TUN interface missing")
        tunFd = fd
        tunOutput = FileOutputStream(fd.fileDescriptor)
        Log.i(TAG, "TUN interface created")

        isActive.set(true)

        // 4. Start packet loops. Netcheck shares this protected mapping.
        startUdpReadThread()
        startTunReadThread()
        performNetcheck(config)
        startTimerLoop()
        sendHandshakeInitiation()

        updateNotification("Connecting...")
        VpnPlugin.notifyStatusChanged()
    }

    fun setActiveCandidate(addr: String, port: Int): Boolean {
        if (tunnelHandle.get() == 0L) return false
        synchronized(destLock) {
            peerAddress = InetSocketAddress(addr, port)
        }
        Log.i(TAG, "Active candidate set to $addr:$port")
        sendHandshakeInitiation()
        VpnPlugin.notifyStatusChanged()
        return true
    }

    fun failTunnel(message: String) {
        lastError = message
        stopTunnel(clearError = false)
        stopSelf()
    }

    private fun startTunReadThread() {
        val fd = tunFd ?: return
        tunReadThread = Thread({
            val input = FileInputStream(fd.fileDescriptor)
            val buf = ByteArray(2048)
            while (isActive.get()) {
                try {
                    val n = input.read(buf)
                    if (n <= 0) continue
                    tunPacketsOut.incrementAndGet()

                    val handle = tunnelHandle.get()
                    if (handle == 0L) continue

                    val enc = ByteArray(n + 80)
                    val encLen = intArrayOf(enc.size)
                    val r = synchronized(wgLock) {
                        TunnelJni.bhWgEncapsulate(handle, buf, n, enc, encLen)
                    }
                    if (r == TunnelJni.WG_WRITE_TO_NET && encLen[0] > 0) {
                        sendUdp(enc, encLen[0])
                    }
                } catch (e: Exception) {
                    if (!isActive.get()) break
                    Log.e(TAG, "TUN read error", e)
                }
            }
        }, "BlackholeVPN.tunRead").also { it.start() }
    }

    private fun startUdpReadThread() {
        val socket = udpSocket ?: return
        udpReadThread = Thread({
            val buf = ByteArray(2048)
            val packet = DatagramPacket(buf, buf.size)
            while (isActive.get()) {
                try {
                    socket.receive(packet)
                    val n = packet.length
                    if (n <= 0) continue
                    if (maybeHandleNetcheck(buf, n)) continue
                    udpPacketsIn.incrementAndGet()
                    handleIncomingUdp(buf, n)
                } catch (e: Exception) {
                    if (!isActive.get()) break
                    Log.e(TAG, "UDP read error", e)
                }
            }
        }, "BlackholeVPN.udpRead").also { it.start() }
    }

    private fun handleIncomingUdp(data: ByteArray, len: Int) {
        val handle = tunnelHandle.get()
        if (handle == 0L) return

        val dst = ByteArray(len + 80)
        val dstLen = intArrayOf(dst.size)

        val r = synchronized(wgLock) {
            TunnelJni.bhWgDecapsulate(handle, data, len, dst, dstLen)
        }

        when (r) {
            TunnelJni.WG_WRITE_TO_TUN -> {
                if (dstLen[0] > 0) {
                    tunPacketsIn.incrementAndGet()
                    writeToTun(dst, dstLen[0])
                }
            }
            TunnelJni.WG_WRITE_TO_NET -> {
                if (dstLen[0] > 0) sendUdp(dst, dstLen[0])
                drainTunnel()
            }
        }
        VpnPlugin.notifyStatusChanged()
    }

    private fun drainTunnel() {
        while (true) {
            val handle = tunnelHandle.get()
            if (handle == 0L) return

            val dst = ByteArray(2048)
            val dstLen = intArrayOf(dst.size)
            val r = synchronized(wgLock) {
                TunnelJni.bhWgDecapsulate(handle, null, 0, dst, dstLen)
            }
            when (r) {
                TunnelJni.WG_WRITE_TO_TUN -> {
                    if (dstLen[0] > 0) {
                        tunPacketsIn.incrementAndGet()
                        writeToTun(dst, dstLen[0])
                    }
                }
                TunnelJni.WG_WRITE_TO_NET -> {
                    if (dstLen[0] > 0) sendUdp(dst, dstLen[0])
                }
                else -> return
            }
        }
    }

    private fun writeToTun(data: ByteArray, len: Int) {
        try {
            tunOutput?.write(data, 0, len)
        } catch (e: Exception) {
            Log.e(TAG, "TUN write error", e)
        }
    }

    private fun sendUdp(data: ByteArray, len: Int) {
        udpPacketsOut.incrementAndGet()
        val socket = udpSocket ?: return
        val dest = synchronized(destLock) { peerAddress } ?: return
        try {
            socket.send(DatagramPacket(data, len, dest))
        } catch (e: Exception) {
            Log.e(TAG, "UDP send error", e)
        }
    }

    private fun sendHandshakeInitiation() {
        val handle = tunnelHandle.get()
        if (handle == 0L) return
        val dst = ByteArray(2048)
        val dstLen = intArrayOf(dst.size)
        val r = synchronized(wgLock) {
            TunnelJni.bhWgForceHandshake(handle, dst, dstLen)
        }
        if (r == TunnelJni.WG_WRITE_TO_NET && dstLen[0] > 0) {
            sendUdp(dst, dstLen[0])
        }
    }

    private fun performNetcheck(config: JSONObject) {
        val host = config.optString("netcheckHost").trim()
        val port = config.optInt("netcheckPort", 0)
        if (host.isEmpty() || port <= 0) return
        val nonce = UUID.randomUUID().toString()
        val payload = """{"type":"netcheck","nonce":"$nonce"}""".toByteArray(Charsets.UTF_8)
        pendingNetcheckNonce = nonce
        try {
            val socket = udpSocket ?: return
            socket.send(DatagramPacket(payload, payload.size, InetSocketAddress(host, port)))
            udpPacketsOut.incrementAndGet()
        } catch (e: Exception) {
            Log.w(TAG, "UDP netcheck failed", e)
            pendingNetcheckNonce = null
        }
    }

    private fun maybeHandleNetcheck(data: ByteArray, len: Int): Boolean {
        val nonce = pendingNetcheckNonce ?: return false
        val text = try {
            String(data, 0, len, Charsets.UTF_8)
        } catch (_: Exception) {
            return false
        }
        if (!text.contains("observedAddr")) return false
        return try {
            val obj = JSONObject(text)
            if (obj.optString("nonce") != nonce) return false
            val addr = obj.optString("observedAddr")
            val port = obj.optInt("observedPort")
            if (addr.isNotEmpty() && port > 0) {
                observedCandidates = JSONArray().put(
                    JSONObject().apply {
                        put("addr", addr)
                        put("port", port)
                        put("scope", "public_observed")
                        put("priority", 180)
                        put("source", "wormhole_netcheck")
                    },
                )
            }
            pendingNetcheckNonce = null
            VpnPlugin.notifyStatusChanged()
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun startTimerLoop() {
        timerFuture = scheduler.scheduleAtFixedRate({
            if (!isActive.get()) return@scheduleAtFixedRate
            try {
                val handle = tunnelHandle.get()
                if (handle == 0L) return@scheduleAtFixedRate
                val dst = ByteArray(2048)
                val dstLen = intArrayOf(dst.size)
                val r = synchronized(wgLock) {
                    TunnelJni.bhWgUpdateTimers(handle, dst, dstLen)
                }
                if (r == TunnelJni.WG_WRITE_TO_NET && dstLen[0] > 0) {
                    sendUdp(dst, dstLen[0])
                }
                val stats = currentWireGuardStats()
                if (stats.handshakeAgeSecs >= 0 && !announcedConnected) {
                    announcedConnected = true
                    updateNotification("Connected")
                    VpnPlugin.notifyStatusChanged()
                } else if (
                    stats.handshakeAgeSecs < 0 &&
                    SystemClock.elapsedRealtime() - startedAtElapsedMs >= HANDSHAKE_TOTAL_BUDGET_MS
                ) {
                    recordFatalError(
                        "WireGuard handshake timed out",
                        RuntimeException("WireGuard handshake timed out"),
                    )
                }
            } catch (t: Throwable) {
                recordFatalError("VPN timer loop failed", t)
            }
        }, 250, 250, TimeUnit.MILLISECONDS)
    }

    fun stopTunnel(clearError: Boolean = false) {
        isActive.set(false)
        timerFuture?.cancel(false)
        timerFuture = null

        tunReadThread?.interrupt()
        tunReadThread = null
        udpReadThread?.interrupt()
        udpReadThread = null

        udpSocket?.close()
        udpSocket = null
        synchronized(destLock) { peerAddress = null }
        pendingNetcheckNonce = null
        tunOutput = null
        tunFd?.close()
        tunFd = null

        val handle = tunnelHandle.getAndSet(0)
        if (handle != 0L) {
            TunnelJni.bhWgTunnelFree(handle)
        }
        if (clearError) {
            lastError = null
        }

        VpnPlugin.notifyStatusChanged()
    }

    fun getStatusPayload(): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val handle = tunnelHandle.get()
        val stats = currentWireGuardStats()
        val handshakeReady = stats.handshakeAgeSecs >= 0
        if (lastError != null && handle == 0L) {
            result["status"] = "error"
            result["connectionMode"] = "direct"
        } else if (isActive.get() && handshakeReady) {
            result["status"] = "connected"
            result["connectionMode"] = "direct"
        } else if (handle != 0L || isActive.get()) {
            result["status"] = "connecting"
            result["connectionMode"] = "direct"
        } else {
            result["status"] = "disconnected"
        }
        result["timestamp"] = currentTimestamp()
        result["clientIp"] = activeConfig?.optString("clientIp")
        result["serverIp"] = activeConfig?.optString("serverIp")
        result["lanPort"] = activeConfig?.optInt("lanPort", 9527)
        result["tunPacketsOut"] = tunPacketsOut.get()
        result["tunPacketsIn"] = tunPacketsIn.get()
        result["udpPacketsOut"] = udpPacketsOut.get()
        result["udpPacketsIn"] = udpPacketsIn.get()
        result["wgTxBytes"] = stats.txBytes
        result["wgRxBytes"] = stats.rxBytes
        result["timeSinceLastHandshakeSecs"] = stats.handshakeAgeSecs
        result["directSessionReady"] = handshakeReady
        result["error"] = lastError
        observedCandidates?.let { result["observedCandidates"] = jsonArrayToList(it) }
        val dest = synchronized(destLock) { peerAddress }
        if (dest != null) {
            result["activeDirectCandidate"] = mapOf(
                "addr" to dest.hostString,
                "port" to dest.port,
            )
        }
        return result
    }

    private data class WireGuardStats(
        val handshakeAgeSecs: Long,
        val txBytes: Long,
        val rxBytes: Long,
    )

    private fun currentWireGuardStats(): WireGuardStats {
        val handle = tunnelHandle.get()
        if (handle == 0L) {
            return WireGuardStats(handshakeAgeSecs = -1, txBytes = 0, rxBytes = 0)
        }
        val stats = LongArray(5)
        return try {
            val ok = synchronized(wgLock) { TunnelJni.bhWgGetStats(handle, stats) == 1 }
            if (ok) {
                WireGuardStats(
                    handshakeAgeSecs = stats[0],
                    txBytes = stats[1],
                    rxBytes = stats[2],
                )
            } else {
                WireGuardStats(handshakeAgeSecs = -1, txBytes = 0, rxBytes = 0)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to read WireGuard stats", t)
            WireGuardStats(handshakeAgeSecs = -1, txBytes = 0, rxBytes = 0)
        }
    }

    private fun jsonArrayToList(array: JSONArray): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>(array.length())
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val map = mutableMapOf<String, Any?>()
            obj.keys().forEach { key -> map[key] = obj.opt(key) }
            out.add(map)
        }
        return out
    }

    override fun onRevoke() {
        Log.i(TAG, "VPN permission revoked")
        stopTunnel(clearError = true)
        stopSelf()
    }

    override fun onDestroy() {
        stopTunnel(clearError = true)
        instance = null
        super.onDestroy()
    }

    private fun createNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "VPN Service", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
            return Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Blackhole VPN")
                .setContentText(text)
                .setSmallIcon(R.drawable.ic_vpn_notification)
                .setOngoing(true)
                .build()
        }
        return Notification.Builder(this)
            .setContentTitle("Blackhole VPN")
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_vpn_notification)
            .setOngoing(true)
            .build()
    }

    private fun updateNotification(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.notify(NOTIFICATION_ID, createNotification(text))
    }

    private fun currentTimestamp(): String {
        val formatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        formatter.timeZone = TimeZone.getTimeZone("UTC")
        return formatter.format(System.currentTimeMillis())
    }

    private fun recordFatalError(summary: String, error: Throwable) {
        Log.e(TAG, summary, error)
        lastError = error.message ?: summary
        stopTunnel(clearError = false)
        stopSelf()
    }
}
