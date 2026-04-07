package dev.icyou.blackhole.voyager

object TunnelJni {
    init {
        System.loadLibrary("tunnel_jni")
    }

    external fun bhWgTunnelNew(configJson: String): Long
    external fun bhWgTunnelFree(tunnel: Long)
    external fun bhWgEncapsulate(tunnel: Long, src: ByteArray, srcLen: Int, dst: ByteArray, dstLen: IntArray): Int
    external fun bhWgDecapsulate(tunnel: Long, src: ByteArray?, srcLen: Int, dst: ByteArray, dstLen: IntArray): Int
    external fun bhWgUpdateTimers(tunnel: Long, dst: ByteArray, dstLen: IntArray): Int
    external fun bhWgGenerateKeypair(pubOut: ByteArray, privOut: ByteArray)
    external fun bhWgGetStats(tunnel: Long, statsOut: LongArray): Int
    external fun bhWgForceHandshake(tunnel: Long, dst: ByteArray, dstLen: IntArray): Int

    const val WG_DONE = 0
    const val WG_WRITE_TO_NET = 1
    const val WG_WRITE_TO_TUN = 2
    const val WG_ERR = -1
}
