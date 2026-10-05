/**
 * High-Throughput CCSDS Space Packet and TM Frame Generator.
 * Author: Aneesh Krishna
 *
 * Implements high-performance CCSDS Telemetry (TM) transfer frame formatting
 * with CRC-16-CCITT integrity verification for stress-testing and benchmarking
 * the Apogee Erlang kernel ingest pipeline.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#define CCSDS_ASM 0x1ACFFC1D
#define DEFAULT_FRAME_SIZE 1024
#define CRC16_POLY 0x1021

static uint16_t crc16_table[256];

static void init_crc16_table(void) {
    for (int i = 0; i < 256; i++) {
        uint16_t curr = (uint16_t)(i << 8);
        for (int j = 0; j < 8; j++) {
            if (curr & 0x8000) {
                curr = (curr << 1) ^ CRC16_POLY;
            } else {
                curr <<= 1;
            }
        }
        crc16_table[i] = curr;
    }
}

static uint16_t compute_crc16(const uint8_t *data, size_t length) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < length; i++) {
        uint8_t tbl_idx = ((crc >> 8) ^ data[i]) & 0xFF;
        crc = (crc << 8) ^ crc16_table[tbl_idx];
    }
    return crc;
}

typedef struct {
    uint16_t scid;
    uint8_t  vcid;
    uint8_t  mcfc;
    uint8_t  vcfc;
} FrameState;

static void build_tm_frame(FrameState *st, uint8_t *buffer, size_t frame_size) {
    if (frame_size < 12) return;

    // Byte 0-3: Attached Sync Marker (ASM)
    buffer[0] = 0x1A;
    buffer[1] = 0xCF;
    buffer[2] = 0xFC;
    buffer[3] = 0x1D;

    // Primary Header (6 bytes: offset 4..9)
    // Version (00), SCID (10 bits), VCID (3 bits), OCF flag (1 bit)
    uint16_t word1 = (0 << 14) | ((st->scid & 0x3FF) << 4) | ((st->vcid & 0x7) << 1) | 0;
    buffer[4] = (word1 >> 8) & 0xFF;
    buffer[5] = word1 & 0xFF;

    buffer[6] = st->mcfc;
    buffer[7] = st->vcfc;

    // First Header Pointer (FHP): 11 bits (set to 0 for packet aligned at start)
    uint16_t word2 = 0x0000;
    buffer[8] = (word2 >> 8) & 0xFF;
    buffer[9] = word2 & 0xFF;

    // Payload (synthetic counters)
    for (size_t i = 10; i < frame_size - 2; i++) {
        buffer[i] = (uint8_t)((i + st->mcfc) & 0xFF);
    }

    // CRC-16 Frame Error Control Field (FECF) computed over header and payload
    uint16_t fecf = compute_crc16(&buffer[4], frame_size - 6);
    buffer[frame_size - 2] = (fecf >> 8) & 0xFF;
    buffer[frame_size - 1] = fecf & 0xFF;

    st->mcfc = (st->mcfc + 1) & 0xFF;
    st->vcfc = (st->vcfc + 1) & 0xFF;
}

int main(int argc, char **argv) {
    size_t count = 100000;
    size_t frame_size = DEFAULT_FRAME_SIZE;
    int benchmark_only = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--bench") == 0) {
            benchmark_only = 1;
        } else if (strcmp(argv[i], "--count") == 0 && i + 1 < argc) {
            count = (size_t)atol(argv[++i]);
        } else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
            frame_size = (size_t)atol(argv[++i]);
        } else if (strcmp(argv[i], "--help") == 0) {
            fprintf(stderr, "Usage: %s [--bench] [--count N] [--size BYTES]\n", argv[0]);
            return 0;
        }
    }

    init_crc16_table();

    uint8_t *frame = (uint8_t *)malloc(frame_size);
    if (!frame) {
        fprintf(stderr, "Memory allocation error\n");
        return 1;
    }

    FrameState state = {
        .scid = 42,
        .vcid = 1,
        .mcfc = 0,
        .vcfc = 0
    };

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    for (size_t i = 0; i < count; i++) {
        build_tm_frame(&state, frame, frame_size);
        if (!benchmark_only) {
            if (i < 5) {
                // Preview first 5 frames
                fprintf(stderr, "Frame %zu ASM: 0x%02X%02X%02X%02X SCID: %u VCID: %u CRC: 0x%02X%02X\n",
                        i, frame[0], frame[1], frame[2], frame[3],
                        state.scid, state.vcid,
                        frame[frame_size - 2], frame[frame_size - 1]);
            }
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed_sec = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    double mb_total = (double)(count * frame_size) / (1024.0 * 1024.0);
    double throughput_mb_s = mb_total / elapsed_sec;
    double fps = (double)count / elapsed_sec;

    fprintf(stderr, "\n--- CCSDS Generator Benchmark Results ---\n");
    fprintf(stderr, "Generated:      %zu frames (%zu bytes each)\n", count, frame_size);
    fprintf(stderr, "Data Volume:    %.2f MB\n", mb_total);
    fprintf(stderr, "Elapsed Time:   %.4f seconds\n", elapsed_sec);
    fprintf(stderr, "Throughput:     %.2f MB/s (%.1f Mbps)\n", throughput_mb_s, throughput_mb_s * 8.0);
    fprintf(stderr, "Frame Rate:     %.0f frames/second\n", fps);

    free(frame);
    return 0;
}
