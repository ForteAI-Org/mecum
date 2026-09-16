//
//  AllocationCounter.c
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

#include "include/AllocationCounter.h"

#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>

// From libmalloc's private/stack_logging.h: type is a bit field, 2 is an
// allocation and 4 a deallocation. Not declared in any SDK header.
typedef void (malloc_logger_t)(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                               uintptr_t arg3, uintptr_t result,
                               uint32_t num_hot_frames_to_skip);
extern malloc_logger_t *malloc_logger;

static _Atomic uint64_t g_allocations = 0;
static _Atomic uint64_t g_frees       = 0;

// Runs inside the allocator: relaxed atomics only, and nothing that allocates.
static void agentseat_bench_counter(uint32_t type, uintptr_t arg1, uintptr_t arg2,
                                    uintptr_t arg3, uintptr_t result,
                                    uint32_t num_hot_frames_to_skip) {
    (void)arg1; (void)arg2; (void)arg3; (void)result; (void)num_hot_frames_to_skip;
    if (type & 2) atomic_fetch_add_explicit(&g_allocations, 1, memory_order_relaxed);
    if (type & 4) atomic_fetch_add_explicit(&g_frees, 1, memory_order_relaxed);
}

uint64_t agentseat_bench_allocations(void) {
    return atomic_load_explicit(&g_allocations, memory_order_relaxed);
}

uint64_t agentseat_bench_frees(void) {
    return atomic_load_explicit(&g_frees, memory_order_relaxed);
}

void agentseat_bench_hook_install(void) { malloc_logger = agentseat_bench_counter; }
void agentseat_bench_hook_remove(void)  { malloc_logger = NULL; }
