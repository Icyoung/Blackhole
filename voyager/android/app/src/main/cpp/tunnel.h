// tunnel.h — C FFI declarations for the Rust tunnel library.
#ifndef TUNNEL_H
#define TUNNEL_H

#include <stddef.h>
#include <stdint.h>

#define BH_WG_DONE         0
#define BH_WG_WRITE_TO_NET 1
#define BH_WG_WRITE_TO_TUN 2
#define BH_WG_ERR         -1

struct bh_wg_stats {
    int64_t  time_since_last_handshake_secs;
    uint64_t tx_bytes;
    uint64_t rx_bytes;
    float    estimated_loss;
    int32_t  estimated_rtt_ms;
};

void *bh_wg_tunnel_new(const char *config_json);
void  bh_wg_tunnel_free(void *tunnel);

int bh_wg_encapsulate(void *tunnel,
                      const uint8_t *src, size_t src_len,
                      uint8_t *dst, size_t *dst_len);

int bh_wg_decapsulate(void *tunnel,
                      const uint8_t *src, size_t src_len,
                      uint8_t *dst, size_t *dst_len);

int bh_wg_update_timers(void *tunnel,
                        uint8_t *dst, size_t *dst_len);

void bh_wg_generate_keypair(uint8_t *pub_out, uint8_t *priv_out);

int bh_wg_get_stats(void *tunnel, struct bh_wg_stats *out_stats);

int bh_wg_force_handshake(void *tunnel,
                          uint8_t *dst, size_t *dst_len);

#endif // TUNNEL_H
