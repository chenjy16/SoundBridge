/*
 * sb-shm-probe — read-only reader of a live SoundBridge shared-memory mapping.
 *
 * WHY THIS EXISTS
 *
 *   The Host's periodic "Buffer underrun" log line interpolates Ints without
 *   `privacy: .public`, so `log stream` shows `<private>` and the counter is not
 *   readable that way. The counters are, however, sitting in the mapping the
 *   Host and the Driver already share, and `RFSharedAudio.h` documents both the
 *   layout and the accessors. This tool opens that file read-only and reads it
 *   with the header's own acquire-load helpers. It never writes, never truncates
 *   and never unlinks: it is an observer, not a participant.
 *
 *   Fields read here are exactly the ones the Driver/Host write:
 *     driver_connected, driver_heartbeat, host_heartbeat,
 *     underrun_count, underrun_frames, overrun_count
 *   plus the negotiated format (sample_rate, channels, ring_capacity_frames).
 *
 * WHAT IT CANNOT DO
 *
 *   It cannot see anything while the Host is not running: the mapping is
 *   unlinked on Host cleanup, so a missing file means "no live path", not
 *   "zero underruns". The tool exits 3 in that case and prints nothing else.
 *
 * BUILD (no build-system change required)
 *
 *   clang -O2 -std=c11 -I packages/shared/include \
 *       -o build/hwvalidate/sb-shm-probe \
 *       tools/hardware-validation/sb-shm-probe.c
 *
 * USE
 *
 *   build/hwvalidate/sb-shm-probe --uid <deviceUID> --once
 *   build/hwvalidate/sb-shm-probe --uid <deviceUID> --interval 1
 *   build/hwvalidate/sb-shm-probe --path /tmp/soundbridge-501-<UID> --once
 *
 * Output is one JSON object per line (JSONL), so a collector can parse it
 * without a schema negotiation round trip.
 */

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "RFSharedAudio.h"

static const char* format_name(RFAudioFormat format) {
    switch (format) {
        case RF_FORMAT_FLOAT32: return "float32";
        case RF_FORMAT_FLOAT64: return "float64";
        case RF_FORMAT_INT16: return "int16";
        case RF_FORMAT_INT24: return "int24";
        case RF_FORMAT_INT32: return "int32";
        default: return "unknown";
    }
}

/* Mirrors PathManager.sanitizeUID: ':', '/' and ' ' become '_'. */
static void sanitize_uid(const char* in, char* out, size_t cap) {
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0' && j + 1 < cap; i++) {
        char c = in[i];
        if (c == ':' || c == '/' || c == ' ') c = '_';
        out[j++] = c;
    }
    out[j] = '\0';
}

/* CoreAudio exposes the proxy device as "<physicalUID>-soundbridge", but the
 * Host keys its mapping by the physical UID (ProxyDeviceManager does the same
 * strip before looking a device up). Accept either form from the operator. */
#define PROXY_UID_SUFFIX "-soundbridge"
static void strip_proxy_suffix(const char* in, char* out, size_t cap) {
    size_t len = strlen(in);
    size_t suffix = strlen(PROXY_UID_SUFFIX);
    if (len > suffix && strcmp(in + (len - suffix), PROXY_UID_SUFFIX) == 0) {
        len -= suffix;
    }
    if (len >= cap) len = cap - 1;
    memcpy(out, in, len);
    out[len] = '\0';
}

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000LL);
}

static void usage(void) {
    fprintf(stderr,
        "sb-shm-probe — read-only reader of a live SoundBridge mapping\n\n"
        "  --uid <UID>        derive /tmp/soundbridge-<owner>-<UID>\n"
        "  --path <path>      use an explicit mapping path\n"
        "  --owner <n>        owning uid for the derived path (default: getuid())\n"
        "  --interval <s>     seconds between samples (default 1.0)\n"
        "  --once             print one sample and exit\n"
        "  --pretty           add a human-readable field alongside the JSON\n\n"
        "Exit codes: 0 ok, 2 usage, 3 mapping not present, 5 invalid header.\n");
}

int main(int argc, char** argv) {
    const char* uid = NULL;
    const char* path = NULL;
    long owner = (long)getuid();
    double interval = 1.0;
    int once = 0;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if (strcmp(a, "--help") == 0 || strcmp(a, "-h") == 0) { usage(); return 0; }
        else if (strcmp(a, "--once") == 0) { once = 1; }
        else if (strcmp(a, "--pretty") == 0) { /* accepted, JSON is always emitted */ }
        else if (strcmp(a, "--uid") == 0 && i + 1 < argc) { uid = argv[++i]; }
        else if (strcmp(a, "--path") == 0 && i + 1 < argc) { path = argv[++i]; }
        else if (strcmp(a, "--owner") == 0 && i + 1 < argc) { owner = atol(argv[++i]); }
        else if (strcmp(a, "--interval") == 0 && i + 1 < argc) { interval = atof(argv[++i]); }
        else { fprintf(stderr, "unknown argument: %s\n", a); usage(); return 2; }
    }

    char derived[1024];
    if (path == NULL) {
        if (uid == NULL) { usage(); return 2; }
        char physical[512];
        char safe[512];
        strip_proxy_suffix(uid, physical, sizeof(physical));
        sanitize_uid(physical, safe, sizeof(safe));
        snprintf(derived, sizeof(derived), "/tmp/soundbridge-%ld-%s", owner, safe);
        path = derived;
    }

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr,
                "{\"error\":\"mapping-not-present\",\"path\":\"%s\",\"errno\":%d,"
                "\"hint\":\"the Host creates this file; it is unlinked on cleanup\"}\n",
                path, errno);
        return 3;
    }

    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < (off_t)sizeof(RFSharedAudio)) {
        fprintf(stderr, "{\"error\":\"mapping-too-small\",\"path\":\"%s\",\"size\":%lld}\n",
                path, (long long)st.st_size);
        close(fd);
        return 5;
    }

    /* Read-only mapping: PROT_READ with no PROT_WRITE, so a stray store traps. */
    void* base = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_SHARED, fd, 0);
    if (base == MAP_FAILED) {
        fprintf(stderr, "{\"error\":\"mmap-failed\",\"errno\":%d}\n", errno);
        close(fd);
        return 5;
    }

    const RFSharedAudio* mem = (const RFSharedAudio*)base;
    RFValidateResult validation = rf_validate_header(mem);
    if (validation != RF_VALIDATE_OK) {
        fprintf(stderr, "{\"error\":\"invalid-header\",\"code\":%d,\"path\":\"%s\"}\n",
                (int)validation, path);
        munmap(base, (size_t)st.st_size);
        close(fd);
        return 5;
    }

    for (;;) {
        printf("{\"t\":%lld,\"path\":\"%s\",\"protocol\":%u,\"headerSize\":%u,"
               "\"sampleRate\":%u,\"channels\":%u,\"ringCapacityFrames\":%u,"
               "\"format\":\"%s\",\"driverConnected\":%u,"
               "\"driverHeartbeat\":%llu,\"hostHeartbeat\":%llu,"
               "\"underrunCount\":%llu,\"underrunFrames\":%u,\"overrunCount\":%llu}\n",
               now_ms(), path,
               mem->protocol_version, mem->header_size,
               mem->sample_rate, mem->channels, mem->ring_capacity_frames,
               format_name(mem->format),
               rf_get_driver_connected(mem),
               (unsigned long long)rf_get_driver_heartbeat(mem),
               (unsigned long long)rf_get_host_heartbeat(mem),
               (unsigned long long)rf_get_underrun_count(mem),
               rf_get_underrun_frames(mem),
               (unsigned long long)rf_get_overrun_count(mem));
        fflush(stdout);
        if (once) break;
        struct timespec ts;
        ts.tv_sec = (time_t)interval;
        ts.tv_nsec = (long)((interval - (double)ts.tv_sec) * 1e9);
        nanosleep(&ts, NULL);
    }

    munmap(base, (size_t)st.st_size);
    close(fd);
    return 0;
}
