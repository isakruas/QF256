/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "qf256.h"
#include <assert.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef QF256_BLIND_HF_CFO_LIMIT_HZ
#error "Removed blind-HF CFO constant is still public"
#endif

_Static_assert(sizeof(qf256_result) == 152, "Unexpected ABI result size");
_Static_assert(QF256_API_VERSION == 1, "Unexpected API version");
_Static_assert(QF256_BLIND_CFO_LIMIT_HZ == 125.0, "Unexpected blind CFO limit");
_Static_assert(QF256_SYNC_KNOWN == 0, "Unexpected known mode");
_Static_assert(QF256_SYNC_BLIND == 1, "Unexpected blind mode");
_Static_assert(offsetof(qf256_result, start_seconds) == 96, "Unexpected ABI result alignment");
_Static_assert(offsetof(qf256_result, snr_2500_db) == 136, "Unexpected ABI SNR alignment");
_Static_assert(offsetof(qf256_result, snr_valid) == 144, "Unexpected ABI validity alignment");

int main(void) {
    int8_t bits[77];
    int32_t written = -1, status = -1;
    qf256_result result;
    float *wave = malloc(2u * QF256_FRAME_SAMPLES * sizeof(float));
    float *capture = calloc(2u * QF256_BLIND_MIN_SAMPLES, sizeof(float));
    assert(wave && capture);
    for (int i=0; i<77; ++i) bits[i] = (int8_t)((i*11+i/5)%2);

    wave[0] = 42.0f;
    qf256_tx_cf32(bits, wave, QF256_FRAME_SAMPLES-1, &written, &status);
    assert(status == QF256_BUFFER_TOO_SMALL && written == 0 && wave[0] == 42.0f);
    bits[7] = -1;
    qf256_tx_cf32(bits, wave, QF256_FRAME_SAMPLES, &written, &status);
    assert(status == QF256_INVALID_BITS && written == 0 && wave[0] == 42.0f);
    bits[7] = (int8_t)((7*11+7/5)%2);
    qf256_tx_cf32(NULL, wave, QF256_FRAME_SAMPLES, &written, &status);
    assert(status == QF256_INVALID_ARGUMENT && written == 0);
    qf256_tx_cf32(bits, wave, QF256_FRAME_SAMPLES, &written, &status);
    assert(status == QF256_OK && written == QF256_FRAME_SAMPLES);

    qf256_rx_cf32(wave, written, QF256_SYNC_KNOWN, &result, &status);
    assert(status == QF256_OK && result.accepted && result.crc_ok);
    assert(memcmp(bits, result.payload, 77) == 0);
    assert(result.start_samples == 0 && result.cfo_hz == 0);
    assert(result.noise_variance > 0 && result.evidence >= QF256_GATE);
    assert(result.snr_valid == 1 && isfinite(result.snr_2500_db));
    assert(result.reserved2 == 0);

    const int offset = 6000;
    const double cfo = -125.0;
    for (int i=0; i<QF256_FRAME_SAMPLES; ++i) {
        double phase = 0.73 + 2.0*acos(-1.0)*cfo*i/QF256_SAMPLE_RATE;
        double re = wave[2*i], im = wave[2*i+1];
        capture[2*(offset+i)] = (float)(0.7*(re*cos(phase)-im*sin(phase)));
        capture[2*(offset+i)+1] = (float)(0.7*(re*sin(phase)+im*cos(phase)));
    }
    qf256_rx_cf32(capture, QF256_BLIND_MIN_SAMPLES, QF256_SYNC_BLIND, &result, &status);
    assert(status == QF256_OK && result.accepted && result.crc_ok);
    assert(memcmp(bits, result.payload, 77) == 0);
    assert(abs(result.start_samples-offset) <= 12 && fabs(result.cfo_hz-cfo) <= 0.1);
    assert(result.snr_valid == 1 && isfinite(result.snr_2500_db));

    memset(capture, 0, 2u * QF256_BLIND_MIN_SAMPLES * sizeof(float));
    const double upper_cfo = 125.0;
    for (int i=0; i<QF256_FRAME_SAMPLES; ++i) {
        double phase = -0.41 + 2.0*acos(-1.0)*upper_cfo*i/QF256_SAMPLE_RATE;
        double re = wave[2*i], im = wave[2*i+1];
        capture[2*(offset+i)] = (float)(0.7*(re*cos(phase)-im*sin(phase)));
        capture[2*(offset+i)+1] = (float)(0.7*(re*sin(phase)+im*cos(phase)));
    }
    qf256_rx_cf32(capture, QF256_BLIND_MIN_SAMPLES, QF256_SYNC_BLIND, &result, &status);
    assert(status == QF256_OK && result.accepted && result.crc_ok);
    assert(memcmp(bits, result.payload, 77) == 0);
    assert(abs(result.start_samples-offset) <= 12 && fabs(result.cfo_hz-upper_cfo) <= 0.1);

    qf256_rx_cf32(wave, QF256_FRAME_SAMPLES, QF256_SYNC_BLIND, &result, &status);
    assert(status == QF256_INVALID_LENGTH && !result.accepted);
    assert(!result.snr_valid);
    qf256_rx_cf32(wave, QF256_MAX_SAMPLES+1, QF256_SYNC_KNOWN, &result, &status);
    assert(status == QF256_INVALID_LENGTH && !result.accepted);
    qf256_rx_cf32(wave, QF256_FRAME_SAMPLES, 9, &result, &status);
    assert(status == QF256_INVALID_SYNC && !result.accepted);
    qf256_rx_cf32(wave, QF256_FRAME_SAMPLES, 2, &result, &status);
    assert(status == QF256_INVALID_SYNC && !result.accepted);
    wave[1] = NAN;
    qf256_rx_cf32(wave, QF256_FRAME_SAMPLES, QF256_SYNC_KNOWN, &result, &status);
    assert(status == QF256_NONFINITE && !result.accepted);
    qf256_rx_cf32(NULL, QF256_FRAME_SAMPLES, QF256_SYNC_KNOWN, &result, &status);
    assert(status == QF256_INVALID_ARGUMENT && !result.accepted);
    qf256_rx_cf32(NULL, -1, 9, NULL, NULL); /* Defined null-status no-op. */
    free(capture);
    free(wave);
    puts("PASS: C ABI layout, validation, SNR, known and blind roundtrips");
    return 0;
}
