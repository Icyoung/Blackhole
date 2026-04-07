package dev.icyou.blackhole.voyager

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import org.json.JSONObject
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
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

        @Volatile var instance: BlackholeVpnService? = null
            private set
    }

    private var tunFd: ParcelFileDescriptor? = null
    private var tunOutput: FileOutputStream? = null
    private val tunnelHandle = AtomicLong(0)
    private var udpSocket: DatagramSocket? = null
    private val isActive = AtomicBoolean(false)
    private var activeConfig: JSONObject? = null
    @Volatile private var lastError: String? = null

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

        // 2. Create UDP socket — protect before connect
        val socket = DatagramSocket()
        if (!protect(socket)) {
            socket.close()
            throw RuntimeException("Failed to protect VPN UDP socket")
        }
        socket.connect(InetSocketAddress(serverAddr, serverPort))
        udpSocket = socket
        Log.i(TAG, "UDP connected to $serverAddr:$serverPort")

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

        val fd = builder.establish() ?: throw RuntimeException("VPN permission not granted")
        tunFd = fd
        tunOutput = FileOutputStream(fd.fileDescriptor)
        Log.i(TAG, "TUN interface created")

        isActive.set(true)

        // 4. Start packet loops
        startUdpReadThread()
        startTunReadThread()
        startTimerLoop()
        sendHandshakeInitiation()

        updateNotification("Connected")
        VpnPlugin.notifyStatusChanged()
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
        try {
            socket.send(DatagramPacket(data, len))
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
            TunnelJni.bhWgUpdateTimers(handle, dst, dstLen)
        }
        if (r == TunnelJni.WG_WRITE_TO_NET && dstLen[0] > 0) {
            sendUdp(dst, dstLen[0])
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
        if (lastError != null && handle == 0L) {
            result["status"] = "error"
        } else if (isActive.get() && udpPacketsIn.get() > 0) {
            result["status"] = "connected"
            result["connectionMode"] = "direct"
        } else if (handle != 0L) {
            result["status"] = "connecting"
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
        result["error"] = lastError

        if (handle != 0L) {
            val stats = LongArray(5)
            try {
                if (TunnelJni.bhWgGetStats(handle, stats) == 1) {
                    result["wgTxBytes"] = stats[1]
                    result["wgRxBytes"] = stats[2]
                }
            } catch (t: Throwable) {
                Log.e(TAG, "Failed to read WireGuard stats", t)
                result["error"] = t.message ?: "Failed to read WireGuard stats"
            }
        }
        return result
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
