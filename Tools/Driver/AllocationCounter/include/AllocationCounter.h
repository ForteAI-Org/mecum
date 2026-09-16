//
//  AllocationCounter.h
//  AgentSeatKit
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 08/09/2026.
//

#ifndef AGENTSEAT_BENCH_SHIM_H
#define AGENTSEAT_BENCH_SHIM_H

#include <stdint.h>

/// Counts heap allocations and frees through libmalloc's `malloc_logger` hook.
///
/// This is the only mechanism found that is both exact and free inside a 50 us
/// window: if the code under measurement allocates
/// nothing, the hook is never called and the whole cost is two relaxed atomic
/// loads at 0.25 ns each. The overhead exists only in the case where the
/// benchmark has to fail.
///
/// It has to be C. The hook is invoked from inside the allocator, so the body
/// must not allocate, and a Swift closure with context would.
///
/// `malloc_logger` is SPI and marked deprecated in libmalloc 812, with an Apple
/// TODO to replace it with a getter/setter pair. It is measurement only: no
/// shipping code path reads it, and it conflicts with MallocStackLogging and
/// with Instruments' Allocations, so do not profile and measure together.

/// Allocations seen since the process started.
uint64_t agentseat_bench_allocations(void);

/// Frees seen since the process started.
uint64_t agentseat_bench_frees(void);

/// Installs the counting hook. The counters keep running until it is removed.
void agentseat_bench_hook_install(void);

/// Removes the hook, restoring whatever libmalloc did before.
void agentseat_bench_hook_remove(void);

#endif /* AGENTSEAT_BENCH_SHIM_H */
