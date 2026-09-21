/* Read-only focus sampler for a bounded research probe. It is not a production
 * primitive, it is not a qualification, and it refuses to run outside the two
 * profiles an ABI record actually covers.
 *
 *   historic  macOS 26A5425a, the build the original SkyLight arm64 read of
 *             _SLPSGetFrontProcess was taken on (2026-09-10). No image UUID was
 *             recorded with that read, so this profile attests a build and an
 *             architecture and nothing else. It is never extended to another
 *             image, and its evidence is not relabelled as the newer one.
 *
 *   research  macOS 26A428 on a Mac16,1 with an arm64 host, the SkyLight arm64e
 *             image 8A3B348E-4637-3685-92D0-6CBC2F36A234 and the LaunchServices
 *             image 00ED6A89-5E67-37AA-9342-51EB93F68EE5 that provides the
 *             delegate (_LSCopyFrontApplication, _LSASNExtractHighAndLowParts)
 *             the wrapper forwards to. Off by default: it needs
 *             --experimental-research-admission on the invocation itself
 *             (ASI-D-054), never a build-wide or permanent switch.
 *
 * Three separate facts are reported and never collapsed into one: whether a
 * static ABI record identifies this image, whether an explicit research
 * admission was requested and granted for this invocation, and the runtime
 * qualification, which is always "not_acquired" here. The audit behind either
 * profile is static: addresses forwarded at offsets 0 and 4, a 32 bit
 * connection id, a 32 bit owner, 8 bytes written into the PSN. Resolving a
 * symbol or compiling against it is not evidence of a runtime effect, of
 * freshness, or of safety. _SLPSGetFrontProcess has a shared memory path and an
 * IPC fallback, so a sample is not an instantaneous picture of the WindowServer
 * and the loop cadence below is not a latency bound.
 *
 * Operator consent to run anything live is a separate human decision, recorded
 * outside this program: passing the preflight is not evidence of it.
 *
 * No focus request and no input is posted, and a transition that was not
 * sampled is never treated as zero.
 */
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

typedef struct { uint32_t high, low; } ProcessSerialNumber;

/* The layout the audit checked, syntax only: 8 bytes, 4 byte alignment, the two
 * words the wrapper forwards addresses of at offsets 0 and 4. */
_Static_assert(sizeof(ProcessSerialNumber) == 8, "the audited PSN is 8 bytes");
_Static_assert(_Alignof(ProcessSerialNumber) == 4, "the audited PSN aligns to 4");
_Static_assert(offsetof(ProcessSerialNumber, high) == 0, "high word at offset 0");
_Static_assert(offsetof(ProcessSerialNumber, low) == 4, "low word at offset 4");

typedef struct {
    int identity;
    uint64_t earliest, latest, readDuration;
} Transition;

/* Exit codes. 9 is the refusal of the admission guard and is distinct from
 * every failure of the sampling itself. */
enum {
    kExitUsage           = 2,
    kExitImageMissing    = 3,
    kExitSymbolMissing   = 4,
    kExitUserWindow      = 5,
    kExitTargetWindow    = 6,
    kExitNoTransition    = 7,
    kExitScheduling      = 8,
    kExitAdmissionRefused = 9
};

static const char kHistoricBuild[]             = "26A5425a";
static const char kResearchBuild[]             = "26A428";
static const char kResearchModel[]             = "Mac16,1";
static const char kAuditedArchitecture[]       = "arm64";
static const char kResearchSkyLightUUID[]      = "8A3B348E-4637-3685-92D0-6CBC2F36A234";
static const char kResearchLaunchServicesUUID[] = "00ED6A89-5E67-37AA-9342-51EB93F68EE5";

/* The identity actually detected on the running system, never what a caller
 * declared. A field is NULL when it could not be read at all. */
typedef struct {
    const char *build;
    const char *hardwareModel;
    const char *architecture;
    const char *skyLightUUID;
    const char *launchServicesUUID;
    int researchOptIn;
} ProbeIdentity;

/* The three states kept apart: which static record identifies this image, what
 * happened to the per invocation research admission, and whether the sampler
 * may proceed. Runtime qualification is not one of the outcomes: it is never
 * acquired here. */
typedef struct {
    const char *evidence;   /* absent | historic_26A5425a | research_26A428 */
    const char *admission;  /* not_requested | granted | refused */
    const char *profile;    /* none | historic-26A5425a | research-26A428 */
    const char *reason;
    int admitted;
} ProbeVerdict;

static const char kRuntimeQualification[] = "not_acquired";

static int present(const char *value) { return value != NULL && value[0] != '\0'; }

static int same(const char *value, const char *expected) {
    return present(value) && strcmp(value, expected) == 0;
}

/* The whole compatibility rule, as a pure function of the detected identity, so
 * the refusals can be exercised offline without loading or calling anything. */
static ProbeVerdict probeAdmission(ProbeIdentity identity) {
    ProbeVerdict verdict;
    verdict.evidence  = "absent";
    verdict.admission = identity.researchOptIn ? "refused" : "not_requested";
    verdict.profile   = "none";
    verdict.reason    = "";
    verdict.admitted  = 0;

    if (!present(identity.build) || !present(identity.hardwareModel)
        || !present(identity.architecture)) {
        verdict.reason = "incomplete identity: build, hardware model and host "
                         "architecture must all be detected";
        return verdict;
    }

    if (same(identity.build, kResearchBuild)) {
        if (!present(identity.skyLightUUID) || !present(identity.launchServicesUUID)) {
            verdict.reason = "incomplete identity: the SkyLight and LaunchServices "
                             "image UUIDs were not read";
            return verdict;
        }
        if (!same(identity.hardwareModel, kResearchModel)) {
            verdict.reason = "hardware model outside the admitted 26A428 profile";
            return verdict;
        }
        if (!same(identity.architecture, kAuditedArchitecture)) {
            verdict.reason = "host architecture outside the admitted 26A428 profile";
            return verdict;
        }
        if (!same(identity.skyLightUUID, kResearchSkyLightUUID)) {
            verdict.reason = "the SkyLight image is not the audited one";
            return verdict;
        }
        if (!same(identity.launchServicesUUID, kResearchLaunchServicesUUID)) {
            verdict.reason = "the LaunchServices delegate image is not the audited one";
            return verdict;
        }
        verdict.evidence = "research_26A428";
        if (!identity.researchOptIn) {
            verdict.reason = "the static record identifies this image and the "
                             "experimental research admission was not requested "
                             "for this invocation";
            return verdict;
        }
        verdict.admission = "granted";
        verdict.profile   = "research-26A428";
        verdict.admitted  = 1;
        verdict.reason    = "admitted for one bounded research probe; no runtime "
                            "qualification and no live consent follow from it";
        return verdict;
    }

    if (same(identity.build, kHistoricBuild)) {
        if (!same(identity.architecture, kAuditedArchitecture)) {
            verdict.reason = "the 26A5425a record was read from an arm64 image and "
                             "covers no other architecture";
            return verdict;
        }
        verdict.evidence = "historic_26A5425a";
        if (identity.researchOptIn) {
            verdict.reason = "the experimental admission names the 26A428 profile "
                             "and does not transfer to the 26A5425a record";
            return verdict;
        }
        verdict.profile  = "historic-26A5425a";
        verdict.admitted = 1;
        verdict.reason   = "the historic 26A5425a record, which attests a build and "
                           "an architecture and no image identity";
        return verdict;
    }

    verdict.reason = "no ABI record covers this build";
    return verdict;
}

static void printJSONString(FILE *out, const char *value) {
    if (!present(value)) { fputs("null", out); return; }
    fputc('"', out);
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
        if (*cursor == '"' || *cursor == '\\') { fputc('\\', out); fputc(*cursor, out); }
        else if (*cursor < 0x20 || *cursor == 0x7f) fputc('?', out);
        else fputc(*cursor, out);
    }
    fputc('"', out);
}

static void printAdmission(
    FILE *out,
    ProbeVerdict verdict,
    ProbeIdentity identity,
    const char *trial
) {
    fputs("FOCUS_ADMISSION {\"static_abi_evidence\":", out);
    printJSONString(out, verdict.evidence);
    fputs(",\"research_admission\":", out);
    printJSONString(out, verdict.admission);
    fputs(",\"runtime_qualification\":", out);
    printJSONString(out, kRuntimeQualification);
    fputs(",\"profile\":", out);
    printJSONString(out, verdict.profile);
    fputs(",\"admitted\":", out);
    fputs(verdict.admitted ? "true" : "false", out);
    fputs(",\"experimental_opt_in\":", out);
    fputs(identity.researchOptIn ? "true" : "false", out);
    fputs(",\"operator_consent\":\"not_evidenced_by_this_preflight\",\"reason\":", out);
    printJSONString(out, verdict.reason);
    fputs(",\"trial\":", out);
    printJSONString(out, trial);
    fputs(",\"detected\":{\"build\":", out);
    printJSONString(out, identity.build);
    fputs(",\"hardware_model\":", out);
    printJSONString(out, identity.hardwareModel);
    fputs(",\"architecture\":", out);
    printJSONString(out, identity.architecture);
    fputs(",\"skylight_uuid\":", out);
    printJSONString(out, identity.skyLightUUID);
    fputs(",\"launch_services_uuid\":", out);
    printJSONString(out, identity.launchServicesUUID);
    fputs("}}\n", out);
    fflush(out);
}

#ifdef FOCUS_PROBE_SELFTEST

/* Offline entry point for the admission table: it evaluates the very guard the
 * sampler uses, on identities supplied as arguments, and loads nothing. No SPI
 * is resolved or called in this build, which is the point of it. */
static const char *suppliedOrMissing(const char *value) {
    return strcmp(value, "-") == 0 ? NULL : value;
}

int main(int argc, char **argv) {
    if (argc != 7) {
        fputs("usage: build model arch skylight-uuid launchservices-uuid optin\n", stderr);
        return kExitUsage;
    }
    if (strcmp(argv[6], "0") != 0 && strcmp(argv[6], "1") != 0) return kExitUsage;
    ProbeIdentity identity = {
        suppliedOrMissing(argv[1]),
        suppliedOrMissing(argv[2]),
        suppliedOrMissing(argv[3]),
        suppliedOrMissing(argv[4]),
        suppliedOrMissing(argv[5]),
        strcmp(argv[6], "1") == 0
    };
    ProbeVerdict verdict = probeAdmission(identity);
    printAdmission(stdout, verdict, identity, "offline-guard-check");
    return verdict.admitted ? 0 : kExitAdmissionRefused;
}

#else

static const char kSkyLightPath[] =
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight";
static const char kLaunchServicesPath[] =
    "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
    "LaunchServices.framework/LaunchServices";

static int compareGap(const void *left, const void *right) {
    uint64_t a = *(const uint64_t *)left, b = *(const uint64_t *)right;
    return (a > b) - (a < b);
}

static int readSysctlString(const char *name, char *buffer, size_t size) {
    size_t length = size;
    buffer[0] = '\0';
    if (sysctlbyname(name, buffer, &length, NULL, 0) != 0) { buffer[0] = '\0'; return 0; }
    buffer[size - 1] = '\0';
    return buffer[0] != '\0';
}

/* The architecture this process actually runs as, not the one it was built for
 * in principle: a translated process is not the audited arm64 host. */
static const char *hostArchitecture(void) {
    int translated = 0;
    size_t size = sizeof translated;
    if (sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0) == 0 && translated)
        return "x86_64-translated";
#if defined(__arm64__) || defined(__aarch64__)
    return "arm64";
#else
    return "x86_64";
#endif
}

static int endsWith(const char *text, const char *suffix) {
    size_t textLength = strlen(text), suffixLength = strlen(suffix);
    return textLength >= suffixLength
        && strcmp(text + textLength - suffixLength, suffix) == 0;
}

/* The UUID recorded in the mapped image, read from its Mach-O header. This
 * inspects the loaded image and calls none of its functions. */
static int imageUUID(const char *nameSuffix, char *out, size_t size) {
    if (size < 37) return 0;
    out[0] = '\0';
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (!name || !endsWith(name, nameSuffix)) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(index);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t step = 0; step < header->ncmds; step++) {
            if (command->cmd == LC_UUID) {
                const uint8_t *value = ((const struct uuid_command *)command)->uuid;
                snprintf(out, size,
                         "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-"
                         "%02X%02X%02X%02X%02X%02X",
                         value[0], value[1], value[2], value[3], value[4], value[5],
                         value[6], value[7], value[8], value[9], value[10], value[11],
                         value[12], value[13], value[14], value[15]);
                return 1;
            }
            command = (const struct load_command *)((const char *)command + command->cmdsize);
        }
    }
    return 0;
}

static int isTrialToken(const char *value) {
    size_t length = strlen(value);
    if (length == 0 || length > 64) return 0;
    for (size_t index = 0; index < length; index++) {
        char character = value[index];
        int allowed = (character >= 'a' && character <= 'z')
                   || (character >= 'A' && character <= 'Z')
                   || (character >= '0' && character <= '9')
                   || character == '-' || character == '_' || character == '.';
        if (!allowed) return 0;
    }
    return 1;
}

int main(int argc, char **argv) {
    const char *positional[3] = {NULL, NULL, NULL};
    int positionalCount = 0, preflightOnly = 0, researchOptIn = 0;
    const char *trial = NULL;
    for (int index = 1; index < argc; index++) {
        const char *argument = argv[index];
        if (strncmp(argument, "--", 2) != 0) {
            if (positionalCount == 3) return kExitUsage;
            positional[positionalCount++] = argument;
        } else if (strcmp(argument, "--experimental-research-admission") == 0) {
            researchOptIn = 1;
        } else if (strcmp(argument, "--preflight") == 0) {
            preflightOnly = 1;
        } else if (strncmp(argument, "--trial=", 8) == 0) {
            trial = argument + 8;
            if (!isTrialToken(trial)) return kExitUsage;
        } else {
            // An unknown option is a refusal, so a misspelled guard flag cannot
            // read as an absent one.
            return kExitUsage;
        }
    }
    if (!preflightOnly && (positionalCount < 2 || positionalCount > 3)) return kExitUsage;
    unsigned samplePeriodUS = positionalCount == 3 ? (unsigned)strtoul(positional[2], NULL, 10) : 100;
    if (samplePeriodUS < 50 || samplePeriodUS > 1000) return kExitUsage;

    char build[64], model[64], skyLightUUID[37] = "", launchServicesUUID[37] = "";
    readSysctlString("kern.osversion", build, sizeof build);
    readSysctlString("hw.model", model, sizeof model);
    const char *architecture = hostArchitecture();

    /* dlopen maps the image and lets its recorded UUID be read. It resolves and
     * calls no SPI: the admission below decides before any of that. */
    void *image = dlopen(kSkyLightPath, RTLD_NOW);
    if (image) imageUUID("/SkyLight", skyLightUUID, sizeof skyLightUUID);
    void *launchServices = NULL;
    if (strcmp(build, kResearchBuild) == 0) {
        launchServices = dlopen(kLaunchServicesPath, RTLD_NOW);
        if (launchServices) imageUUID("/LaunchServices", launchServicesUUID, sizeof launchServicesUUID);
    }

    ProbeIdentity identity = {
        build[0] ? build : NULL,
        model[0] ? model : NULL,
        architecture,
        skyLightUUID[0] ? skyLightUUID : NULL,
        launchServicesUUID[0] ? launchServicesUUID : NULL,
        researchOptIn
    };
    ProbeVerdict verdict = probeAdmission(identity);
    printAdmission(stdout, verdict, identity, trial ? trial : "unidentified");
    if (!verdict.admitted) {
        if (launchServices) dlclose(launchServices);
        if (image) dlclose(image);
        return kExitAdmissionRefused;
    }
    if (preflightOnly) {
        if (launchServices) dlclose(launchServices);
        if (image) dlclose(image);
        return 0;
    }
    if (!image) return kExitImageMissing;

    /* Only the bounded read-only sampler gets this scheduling hint. */
    int schedulingCode = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    if (schedulingCode) return kExitScheduling;
    int32_t (*front)(ProcessSerialNumber *) = dlsym(image, "_SLPSGetFrontProcess");
    int32_t (*mainID)(void) = dlsym(image, "SLSMainConnectionID");
    int32_t (*owner)(int32_t, uint32_t, int32_t *) = dlsym(image, "SLSGetWindowOwner");
    int32_t (*serialNumber)(int32_t, ProcessSerialNumber *) = dlsym(image, "SLSGetConnectionPSN");
    if (!front || !mainID || !owner || !serialNumber) return kExitSymbolMissing;

    ProcessSerialNumber user = {0}, target = {0};
    int32_t connection = 0;
    if (owner(mainID(), strtoul(positional[0], NULL, 10), &connection)
        || serialNumber(connection, &user)) return kExitUserWindow;
    if (owner(mainID(), strtoul(positional[1], NULL, 10), &connection)
        || serialNumber(connection, &target)) return kExitTargetWindow;

    Transition transitions[32];
    int count = 0, previous = -1, sawTarget = 0;
    uint64_t largestGap = 0, last = 0, previousBefore = 0;
    uint64_t gaps[65536], gapCount = 0, sampleCount = 0, largestRead = 0;
    uint64_t cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID);
    uint64_t start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    // The deadline is only tested between two reads: a native call that blocks
    // inside the image runs to its own end, and the 4 s budget does not renew.
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
        int identityCode = code ? -2 :
            (current.high == user.high && current.low == user.low ? 0 :
             (current.high == target.high && current.low == target.low ? 1 : 2));
        if (identityCode != previous && count < 32) {
            transitions[count++] = (Transition){identityCode, previousBefore, after, after - before};
            previous = identityCode;
        }
        previousBefore = before;
        if (identityCode == 1) sawTarget = 1;
        if (sawTarget && identityCode == 0) break;
        usleep(samplePeriodUS);
    }
    uint64_t cpu = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart;
    uint64_t wall = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    qsort(gaps, gapCount, sizeof(uint64_t), compareGap);
    printf("FOCUS_SERVER {\"sample_period_us\":%u,\"samples\":%llu,\"cpu_ns\":%llu,"
           "\"wall_ns\":%llu,\"max_read_ns\":%llu,\"p99_sample_gap_ns\":%llu,"
           "\"max_sample_gap_ns\":%llu,\"loop_budget_ns\":4000000000,"
           "\"blocked_native_call_interrupted\":false,\"profile\":\"%s\","
           "\"runtime_qualification\":\"%s\",\"trial\":\"%s\",\"transitions\":[",
           samplePeriodUS,
           (unsigned long long)sampleCount, (unsigned long long)cpu, (unsigned long long)wall,
           (unsigned long long)largestRead, (unsigned long long)(gapCount ? gaps[(gapCount - 1) * 99 / 100] : 0),
           (unsigned long long)largestGap, verdict.profile, kRuntimeQualification,
           trial ? trial : "unidentified");
    for (int index = 0; index < count; index++) {
        Transition value = transitions[index];
        printf("%s{\"identity\":%d,\"at_ns\":%llu,\"read_ns\":%llu,\"lower_ns\":%llu}",
               index ? "," : "", value.identity, (unsigned long long)value.latest,
               (unsigned long long)value.readDuration, (unsigned long long)value.earliest);
    }
    puts("]}");
    if (launchServices) dlclose(launchServices);
    dlclose(image);
    return sawTarget ? 0 : kExitNoTransition;
}

#endif
