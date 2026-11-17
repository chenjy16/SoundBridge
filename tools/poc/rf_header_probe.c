// SoundBridge 1.2.0 PoC — read-only inspection of a live shared memory segment.
//
// Prints the protocol header fields (including volume state) without writing.
//
// Build/run:
//   cc -O2 -I packages/host/Sources/CSoundBridgeAudio/include \
//      tools/poc/rf_header_probe.c -o /tmp/rf_header_probe
//   /tmp/rf_header_probe /tmp/soundbridge-<uid>

#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "RFSharedAudio.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <shared-memory-path>\n", argv[0]);
        return 2;
    }

    const char* path = argv[1];
    struct stat st;
    if (stat(path, &st) != 0) {
        perror("stat");
        return 1;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    void* mem = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (mem == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    const RFSharedAudio* s = (const RFSharedAudio*)mem;

    printf("file:              %s\n", path);
    printf("file size:         %lld bytes\n", (long long)st.st_size);
    printf("sizeof(RFSharedAudio): %zu bytes\n", sizeof(RFSharedAudio));
    printf("sizeof(RFEQSnapshot):  %zu bytes\n", sizeof(RFEQSnapshot));
    printf("\n");

    printf("protocol_version: 0x%08x (expected 0x%08x)  %s\n",
           s->protocol_version, RF_AUDIO_PROTOCOL_VERSION,
           s->protocol_version == RF_AUDIO_PROTOCOL_VERSION ? "MATCH" : "MISMATCH");
    printf("header_size:      %u\n", s->header_size);
    printf("\n");

    printf("sample_rate:      %u\n", s->sample_rate);
    printf("channels:         %u\n", s->channels);
    printf("format:           %u\n", s->format);
    printf("bytes_per_sample: %u\n", s->bytes_per_sample);
    printf("bytes_per_frame:  %u\n", s->bytes_per_frame);
    printf("ring_capacity_frames: %u\n", s->ring_capacity_frames);
    printf("ring_duration_ms: %u\n", s->ring_duration_ms);
    printf("\n");

    printf("driver_connected: %u\n", atomic_load(&s->driver_connected));
    printf("host_connected:   %u\n", atomic_load(&s->host_connected));
    printf("driver_heartbeat: %llu\n", (unsigned long long)atomic_load(&s->driver_heartbeat));
    printf("host_heartbeat:   %llu\n", (unsigned long long)atomic_load(&s->host_heartbeat));
    printf("\n");

    printf("volume_scalar:    %.6f   <-- user volume as seen by the host\n",
           atomic_load(&s->volume_scalar));
    printf("mute_state:       %d\n", atomic_load(&s->mute_state));
    printf("eq_sequence:      %u\n", atomic_load(&s->eq_sequence));
    printf("\n");

    printf("write_index:      %llu\n", (unsigned long long)atomic_load(&s->write_index));
    printf("read_index:       %llu\n", (unsigned long long)atomic_load(&s->read_index));
    printf("frames_written:   %llu\n", (unsigned long long)atomic_load(&s->total_frames_written));
    printf("frames_read:      %llu\n", (unsigned long long)atomic_load(&s->total_frames_read));
    printf("overrun_count:    %llu\n", (unsigned long long)atomic_load(&s->overrun_count));
    printf("underrun_count:   %llu\n", (unsigned long long)atomic_load(&s->underrun_count));
    printf("format_mismatch:  %llu\n", (unsigned long long)atomic_load(&s->format_mismatch_count));

    munmap(mem, (size_t)st.st_size);
    return 0;
}
