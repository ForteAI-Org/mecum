/* Read-only measurement helper for macOS 26A5425a, not a production primitive.
 * _SLPSGetFrontProcess ABI checked in SkyLight arm64 disassembly, 2026-09-10.
 * Every transition has a lower and upper time bound. No focus request or input
 * is posted, and a transition that was not sampled is never treated as zero.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <pthread.h>
#include <sys/qos.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint32_t high, low; } ProcessSerialNumber;
typedef struct {
    int identity;
    uint64_t earliest, latest, readDuration;
} Transition;

static int compareGap(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) return 2;
    unsigned samplePeriodUS = argc == 4 ? strtoul(argv[3], NULL, 10) : 100;
    if (samplePeriodUS < 50 || samplePeriodUS > 1000) return 2;
    /* Only the bounded read-only sampler gets this scheduling hint. */
    int schedulingCode = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    if (schedulingCode) return 8;
    void *image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
    if (!image) return 3;
    int32_t (*front)(ProcessSerialNumber *) = dlsym(image, "_SLPSGetFrontProcess");
    int32_t (*mainID)(void) = dlsym(image, "SLSMainConnectionID");
    int32_t (*owner)(int32_t, uint32_t, int32_t *) = dlsym(image, "SLSGetWindowOwner");
    int32_t (*serialNumber)(int32_t, ProcessSerialNumber *) = dlsym(image, "SLSGetConnectionPSN");
    if (!front || !mainID || !owner || !serialNumber) return 4;

    ProcessSerialNumber user = {0}, target = {0};
    int32_t connection = 0;
    if (owner(mainID(), strtoul(argv[1], NULL, 10), &connection) || serialNumber(connection, &user)) return 5;
    if (owner(mainID(), strtoul(argv[2], NULL, 10), &connection) || serialNumber(connection, &target)) return 6;

    Transition transitions[32];
    int count = 0, previous = -1, sawTarget = 0;
    uint64_t largestGap = 0, last = 0, previousBefore = 0;
    uint64_t gaps[65536], gapCount = 0, sampleCount = 0, largestRead = 0;
    uint64_t cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start < 4000000000ULL) {
        ProcessSerialNumber current = {0};
        uint64_t before = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        int code = front(&current);
        uint64_t after = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        sampleCount++;
        if (after - before > largestRead) largestRead = after - before;
        if (last) {
            if (after - last > largestGap) largestGap = after - last;
            if (gapCount < 65536) gaps[gapCount++] = after - last;
        }
        last = after;
        int identity = code ? -2 :
            (current.high == user.high && current.low == user.low ? 0 :
             (current.high == target.high && current.low == target.low ? 1 : 2));
        if (identity != previous && count < 32) {
            transitions[count++] = (Transition){identity, previousBefore, after, after - before};
            previous = identity;
        }
        previousBefore = before;
        if (identity == 1) sawTarget = 1;
        if (sawTarget && identity == 0) break;
        usleep(samplePeriodUS);
    }
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart;
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    qsort(gaps, gapCount, sizeof(uint64_t), compareGap);
    printf("FOCUS_SERVER {\"sample_period_us\":%u,\"samples\":%llu,\"cpu_ns\":%llu,"
           "\"wall_ns\":%llu,\"max_read_ns\":%llu,\"p99_sample_gap_ns\":%llu,"
           "\"max_sample_gap_ns\":%llu,\"transitions\":[", samplePeriodUS,
           (unsigned long long)sampleCount, (unsigned long long)cpu, (unsigned long long)wall,
           (unsigned long long)largestRead, (unsigned long long)(gapCount ? gaps[(gapCount - 1) * 99 / 100] : 0),
           (unsigned long long)largestGap);
    for (int index = 0; index < count; index++) {
        Transition value = transitions[index];
        printf("%s{\"identity\":%d,\"at_ns\":%llu,\"read_ns\":%llu,\"lower_ns\":%llu}",
               index ? "," : "", value.identity, (unsigned long long)value.latest,
               (unsigned long long)value.readDuration, (unsigned long long)value.earliest);
    }
    puts("]}");
    dlclose(image);
    return sawTarget ? 0 : 7;
}
