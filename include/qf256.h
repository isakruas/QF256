/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef QF256_H
#define QF256_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    QF256_API_VERSION = 1,
    QF256_SAMPLE_RATE = 12000,
    QF256_FRAME_SAMPLES = 116800,
    QF256_PAYLOAD_BITS = 77,
    QF256_BLIND_MIN_SAMPLES = 125200,
    QF256_MAX_SAMPLES = 180000,
    QF256_SYNC_KNOWN = 0,
    QF256_SYNC_BLIND = 1
};
#define QF256_GATE 30.220758775848424
#define QF256_SNR_REFERENCE_HZ 2500.0
#define QF256_BLIND_CFO_LIMIT_HZ 125.0

enum qf256_status {
    QF256_OK = 0,
    QF256_INVALID_BITS = 1,
    QF256_INVALID_SYNC = 2,
    QF256_INVALID_LENGTH = 3,
    QF256_NONFINITE = 4,
    QF256_BUFFER_TOO_SMALL = 5,
    QF256_INVALID_ARGUMENT = 6,
    QF256_NUMERIC_RANGE = 7
};

typedef struct qf256_result {
    int8_t payload[77];       /* Raw decoder output; deliver only if accepted=1. */
    int8_t reserved[3];       /* Zero; explicit alignment bytes. */
    int32_t crc_ok;           /* Raw CRC/FEC check, 0 or 1. */
    int32_t accepted;         /* CRC/FEC AND evidence >= QF256_GATE. */
    int32_t start_samples;    /* Zero-based offset within the input capture. */
    int32_t iterations;
    double start_seconds;
    double cfo_hz;
    double noise_variance;    /* Equivalent prefilter white-noise variance fs*N0. */
    double evidence;          /* Pilot energy / estimated N0 - 16; not a probability. */
    double latency_ms;        /* Core process CPU time; not end-to-end wall time. */
    double snr_2500_db;       /* Estimated active-frame SNR in 2500 Hz. */
    int32_t snr_valid;        /* 1 only when the CRC-verified estimate is valid. */
    int32_t reserved2;        /* Zero; reserved for future extension. */
} qf256_result;

/* IQ is float32 [I0,Q0,I1,Q1,...]. Counts are COMPLEX samples, by value.
 * Buffers must be allocated by the caller; pointers must not alias.
 * All pointer arguments are required. These calls are NOT thread-safe. */
void qf256_tx_cf32(const int8_t payload77[77], float *iq_interleaved,
                   int32_t capacity_complex, int32_t *written, int32_t *status);
void qf256_rx_cf32(const float *iq_interleaved, int32_t ncomplex,
                   int32_t sync_mode, qf256_result *result, int32_t *status);

#ifdef __cplusplus
}
#endif
#endif
