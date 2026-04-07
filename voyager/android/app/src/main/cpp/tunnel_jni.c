// tunnel_jni.c — JNI shim forwarding to Rust tunnel FFI.
#include <jni.h>
#include <string.h>
#include "tunnel.h"

// bh_wg_tunnel_new(configJson: String): Long
JNIEXPORT jlong JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgTunnelNew(JNIEnv *env, jobject thiz, jstring config_json) {
    const char *json = (*env)->GetStringUTFChars(env, config_json, NULL);
    if (!json) return 0;
    void *handle = bh_wg_tunnel_new(json);
    (*env)->ReleaseStringUTFChars(env, config_json, json);
    return (jlong)(intptr_t)handle;
}

// bh_wg_tunnel_free(tunnel: Long)
JNIEXPORT void JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgTunnelFree(JNIEnv *env, jobject thiz, jlong tunnel) {
    bh_wg_tunnel_free((void *)(intptr_t)tunnel);
}

// bh_wg_encapsulate(tunnel, src, srcLen, dst, dstLen): Int
JNIEXPORT jint JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgEncapsulate(JNIEnv *env, jobject thiz,
                         jlong tunnel, jbyteArray src, jint src_len,
                         jbyteArray dst, jintArray dst_len_arr) {
    jbyte *src_buf = (*env)->GetByteArrayElements(env, src, NULL);
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    jint *len_ptr = (*env)->GetIntArrayElements(env, dst_len_arr, NULL);

    size_t dst_len = (size_t)len_ptr[0];
    int r = bh_wg_encapsulate((void *)(intptr_t)tunnel,
                              (const uint8_t *)src_buf, (size_t)src_len,
                              (uint8_t *)dst_buf, &dst_len);
    len_ptr[0] = (jint)dst_len;

    (*env)->ReleaseByteArrayElements(env, src, src_buf, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);
    (*env)->ReleaseIntArrayElements(env, dst_len_arr, len_ptr, 0);
    return r;
}

// bh_wg_decapsulate(tunnel, src, srcLen, dst, dstLen): Int
JNIEXPORT jint JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgDecapsulate(JNIEnv *env, jobject thiz,
                         jlong tunnel, jbyteArray src, jint src_len,
                         jbyteArray dst, jintArray dst_len_arr) {
    const uint8_t *src_buf = NULL;
    if (src != NULL) {
        src_buf = (const uint8_t *)(*env)->GetByteArrayElements(env, src, NULL);
    }
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    jint *len_ptr = (*env)->GetIntArrayElements(env, dst_len_arr, NULL);

    size_t dst_len = (size_t)len_ptr[0];
    int r = bh_wg_decapsulate((void *)(intptr_t)tunnel,
                              src_buf, (size_t)src_len,
                              (uint8_t *)dst_buf, &dst_len);
    len_ptr[0] = (jint)dst_len;

    if (src != NULL) {
        (*env)->ReleaseByteArrayElements(env, src, (jbyte *)src_buf, JNI_ABORT);
    }
    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);
    (*env)->ReleaseIntArrayElements(env, dst_len_arr, len_ptr, 0);
    return r;
}

// bh_wg_update_timers(tunnel, dst, dstLen): Int
JNIEXPORT jint JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgUpdateTimers(JNIEnv *env, jobject thiz,
                          jlong tunnel, jbyteArray dst, jintArray dst_len_arr) {
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    jint *len_ptr = (*env)->GetIntArrayElements(env, dst_len_arr, NULL);

    size_t dst_len = (size_t)len_ptr[0];
    int r = bh_wg_update_timers((void *)(intptr_t)tunnel,
                                (uint8_t *)dst_buf, &dst_len);
    len_ptr[0] = (jint)dst_len;

    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);
    (*env)->ReleaseIntArrayElements(env, dst_len_arr, len_ptr, 0);
    return r;
}

// bh_wg_generate_keypair(pubOut, privOut)
JNIEXPORT void JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgGenerateKeypair(JNIEnv *env, jobject thiz,
                             jbyteArray pub_out, jbyteArray priv_out) {
    jbyte *pub_buf = (*env)->GetByteArrayElements(env, pub_out, NULL);
    jbyte *priv_buf = (*env)->GetByteArrayElements(env, priv_out, NULL);

    bh_wg_generate_keypair((uint8_t *)pub_buf, (uint8_t *)priv_buf);

    (*env)->ReleaseByteArrayElements(env, pub_out, pub_buf, 0);
    (*env)->ReleaseByteArrayElements(env, priv_out, priv_buf, 0);
}

// bh_wg_get_stats(tunnel, statsOut): Int
// statsOut is a LongArray[5]:
//   [0] time_since_last_handshake_secs, [1] tx_bytes, [2] rx_bytes,
//   [3] estimated_loss (float bits), [4] estimated_rtt_ms
JNIEXPORT jint JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgGetStats(JNIEnv *env, jobject thiz,
                      jlong tunnel, jlongArray stats_out) {
    struct bh_wg_stats stats;
    int r = bh_wg_get_stats((void *)(intptr_t)tunnel, &stats);
    if (r == 1) {
        jlong buf[5];
        buf[0] = (jlong)stats.time_since_last_handshake_secs;
        buf[1] = (jlong)stats.tx_bytes;
        buf[2] = (jlong)stats.rx_bytes;
        uint32_t loss_bits;
        memcpy(&loss_bits, &stats.estimated_loss, sizeof(loss_bits));
        buf[3] = (jlong)loss_bits;
        buf[4] = (jlong)stats.estimated_rtt_ms;
        (*env)->SetLongArrayRegion(env, stats_out, 0, 5, buf);
    }
    return r;
}

// bh_wg_force_handshake(tunnel, dst, dstLen): Int
JNIEXPORT jint JNICALL
Java_dev_icyou_blackhole_voyager_TunnelJni_bhWgForceHandshake(JNIEnv *env, jobject thiz,
                            jlong tunnel, jbyteArray dst, jintArray dst_len_arr) {
    jbyte *dst_buf = (*env)->GetByteArrayElements(env, dst, NULL);
    jint *len_ptr = (*env)->GetIntArrayElements(env, dst_len_arr, NULL);

    size_t dst_len = (size_t)len_ptr[0];
    int r = bh_wg_force_handshake((void *)(intptr_t)tunnel,
                                  (uint8_t *)dst_buf, &dst_len);
    len_ptr[0] = (jint)dst_len;

    (*env)->ReleaseByteArrayElements(env, dst, dst_buf, 0);
    (*env)->ReleaseIntArrayElements(env, dst_len_arr, len_ptr, 0);
    return r;
}
