# PCRE2 Thread Safety Analysis

## Executive Summary

**The PCRE2 native API is designed to be thread-safe.** The library contains no static or global mutable variables that would cause data races during normal operation. However, proper usage patterns must be followed, and certain edge cases require external synchronization.

Key findings:
- **Compiled patterns are thread-safe for reading** - The same `pcre2_code` can be used by multiple threads simultaneously for matching
- **Match data blocks must be thread-local** - Each thread needs its own `pcre2_match_data` instance
- **JIT stacks must be thread-local** - Each thread using JIT needs its own `pcre2_jit_stack`
- **The POSIX wrapper API is explicitly NOT thread-safe** - Do not use `pcre2posix.h` functions in multithreaded code
- **Contexts can be shared read-only** - Compile/match contexts can be shared if never modified

## Official Documentation Statement

From `/tmp/pcre2/doc/pcre2api.3` (lines 560-567):

> MULTITHREADING
>
> In a multithreaded application it is important to keep thread-specific data
> separate from data that can be shared between threads. The PCRE2 library code
> itself is **thread-safe: it contains no static or global variables**. The API is
> designed to be fairly simple for non-threaded applications while at the same
> time ensuring that multithreaded applications can use it.

## Detailed Analysis

### 1. Global Variables and Static State

The PCRE2 library source was analyzed for static/global mutable state:

#### Thread-Safe Static Data (Constants Only)
- **Character tables** (`pcre2_chartables.c`): `PRIV(default_tables)[]` - Read-only lookup tables
- **Default contexts** (`pcre2_context.c`): `PRIV(default_compile_context)`, `PRIV(default_match_context)`, `PRIV(default_convert_context)` - Read-only default values
- **Error message tables** (`pcre2_error.c`): `compile_error_texts[]`, `match_error_texts[]` - Read-only strings
- **Opcode tables** (`pcre2_dfa_match.c`, `pcre2_match.c`): Various lookup tables - All const

**Source location:** `/tmp/pcre2/src/pcre2_context.c` lines 129-142, 163-178, 199-208

#### Potential Race Condition in JIT Allocator Check

**File:** `/tmp/pcre2/src/pcre2_jit_compile.c` lines 14297-14311

```c
static int executable_allocator_is_working = -1;

if (executable_allocator_is_working == -1)
  {
  /* Checks whether the executable allocator is working. This check
     might run multiple times in multi-threaded environments, but the
     result should not be affected by it. */
  exec_memory = SLJIT_MALLOC_EXEC(32, NULL);
  if (exec_memory != NULL)
    {
    SLJIT_FREE_EXEC(((sljit_u8*)(exec_memory)) + SLJIT_EXEC_OFFSET(exec_memory), NULL);
    executable_allocator_is_working = 1;
    }
  else executable_allocator_is_working = 0;
  }
```

**Assessment:** This is a benign race. The code explicitly acknowledges that "this check might run multiple times in multi-threaded environments, but the result should not be affected by it." The variable transitions from -1 to either 0 or 1, and multiple threads may perform the check redundantly, but the final value will be consistent. The worst case is wasted work, not incorrect behavior.

**Severity:** Low (informational)

### 2. Compiled Pattern Thread Safety

**Compiled patterns (`pcre2_code`) ARE thread-safe for matching.**

From documentation:
> A pointer to the compiled form of a pattern is returned to the user when
> `pcre2_compile()` is successful. The data in the compiled pattern is fixed,
> and does not change when the pattern is matched. Therefore, it is **thread-safe,
> that is, the same compiled pattern can be used by more than one thread
> simultaneously**.

**Caveat for lazy compilation:** If patterns are compiled on-demand and shared:
```c
// Thread-safe pattern for lazy compilation:
if (pointer == NULL) {
  lock(write_lock);
  if (pointer == NULL)    // Double-check after acquiring lock
    pointer = pcre2_compile(...);
  unlock(write_lock);
}
```

**Source location:** `/tmp/pcre2/doc/pcre2api.3` lines 575-613

### 3. JIT Compilation Thread Safety

**JIT compilation (`pcre2_jit_compile()`) modifies the compiled code block and is NOT thread-safe.**

From documentation:
> JIT compilation updates a value within the compiled code block, so a
> thread must gain unique write access to the pointer before calling
> `pcre2_jit_compile()`.

**Mitigation options:**
1. JIT-compile patterns before spawning threads
2. Use `pcre2_code_copy()` to get a private copy before JIT compilation
3. Protect JIT compilation with a mutex

**Source location:** `/tmp/pcre2/doc/pcre2api.3` lines 634-640

### 4. JIT Stack Thread Safety

**JIT stacks MUST be thread-local.**

From `/tmp/pcre2/doc/pcre2jit.3` lines 289-303:

> In a multithread application, if you do not specify a JIT stack, or if you
> assign or pass back NULL from a callback, that is thread-safe, because each
> thread has its own machine stack. However, if you assign or pass back a
> non-NULL JIT stack, this must be a **different stack for each thread** so that the
> application is thread-safe.

**Recommended pattern:**
```c
// During thread initialization
thread_local_var = pcre2_jit_stack_create(...)

// During thread exit
pcre2_jit_stack_free(thread_local_var)

// Use a one-line callback function
return thread_local_var
```

**Source location:** `/tmp/pcre2/doc/pcre2jit.3` lines 302-312

### 5. Match Data Block Thread Safety

**Each thread MUST have its own `pcre2_match_data` block.**

From documentation:
> The matching functions need a block of memory for storing the results of a
> match. This includes details of what was matched, as well as additional
> information such as the name of a (*MARK) setting. **Each thread must provide its
> own copy of this memory.**

The match data block also holds heap frames for backtracking (since release 10.41), making it even more critical that each thread has its own.

**Source location:** `/tmp/pcre2/doc/pcre2api.3` lines 660-666

### 6. Context Thread Safety

**Contexts can be shared if never modified.**

From documentation:
> In a multithreaded application, if the parameters in a context are values that
> are never changed, the same context can be used by all the threads. However, if
> any thread needs to change any value in a context, it must make its own
> thread-specific copy.

**Safe pattern:**
```c
// At startup - create shared read-only context
pcre2_compile_context *shared_cctx = pcre2_compile_context_create(NULL);
pcre2_set_newline(shared_cctx, PCRE2_NEWLINE_LF);
// ... set all desired options ...

// In threads - use directly (read-only) OR copy if modification needed
pcre2_compile_context *thread_cctx = pcre2_compile_context_copy(shared_cctx);
```

**Source location:** `/tmp/pcre2/doc/pcre2api.3` lines 654-657

### 7. Serialization/Deserialization Race Condition

**Known issue:** Patterns deserialized from the same byte stream share a reference-counted character table. The reference count is NOT protected by locking.

From `/tmp/pcre2/doc/pcre2serialize.3` lines 167-173:
> There is a potential race issue if you are using multiple patterns that were
> decoded from a single byte stream in a multithreaded application. A single copy
> of the character tables is used by all the decoded patterns and a reference
> count is used to arrange for its memory to be automatically freed when the last
> pattern is freed, but **there is no locking on this reference count**. Therefore,
> if you want to call `pcre2_code_free()` for these patterns in different threads,
> you must arrange your own locking.

**Source location:** `/tmp/pcre2/src/pcre2_compile.c` lines 1212-1225

```c
if ((code->flags & PCRE2_DEREF_TABLES) != 0)
  {
  ref_count = (PCRE2_SIZE *)(code->tables + TABLES_LENGTH);
  if (*ref_count > 0)
    {
    (*ref_count)--;  // <-- NOT ATOMIC!
    if (*ref_count == 0)
      code->memctl.free((void *)code->tables, code->memctl.memory_data);
    }
  }
```

**Severity:** Medium - Only affects code using serialization/deserialization

**Mitigation:** Protect `pcre2_code_free()` calls with a mutex when patterns share deserialized tables

### 8. POSIX Wrapper API (NOT Thread-Safe)

**The POSIX wrapper (`pcre2posix.h`) is explicitly NOT thread-safe.**

From `/tmp/pcre2/doc/pcre2posix.3` lines 34-36:
> **IMPORTANT NOTE**: The functions described here are NOT thread-safe, and
> should not be used in multi-threaded applications. They are also limited to
> processing subjects that are not bigger than 2GB. Use the native API instead.

**Affected functions:**
- `pcre2_regcomp()`
- `pcre2_regexec()`
- `pcre2_regerror()`
- `pcre2_regfree()`

**Reason:** The POSIX API stores per-pattern match data in the `regex_t` structure, which is modified during matching. This makes the same compiled pattern unsafe to use from multiple threads.

**Source location:** `/tmp/pcre2/src/pcre2posix.c` lines 325, 360

## Recommended Mitigations

### For Zig/C Wrapper Code

1. **Do NOT use the POSIX wrapper API** in multithreaded code

2. **Create thread-local storage for:**
   - `pcre2_match_data` blocks
   - `pcre2_jit_stack` (if using JIT with custom stacks)

3. **If using serialization:**
   - Either deserialize patterns separately per thread
   - Or protect `pcre2_code_free()` with a mutex for deserialized patterns

4. **For lazy JIT compilation:**
   ```c
   // Safe lazy JIT pattern
   if (!pattern_jit_compiled) {
       lock(mutex);
       if (!pattern_jit_compiled) {
           pcre2_jit_compile(code, PCRE2_JIT_COMPLETE);
           pattern_jit_compiled = true;
       }
       unlock(mutex);
   }
   ```

### Compile Flags

**No special compile flags are needed for thread safety.** The library is thread-safe by design when used correctly.

However, if building a custom version:
- `SUPPORT_JIT` enables JIT compilation (requires per-thread stacks)
- No thread-safety-specific build options exist

## Summary Table

| Component | Thread-Safe? | Notes |
|-----------|--------------|-------|
| Compiled patterns (read) | Yes | Can share between threads |
| Compiled patterns (JIT compile) | No | Requires synchronization |
| Match data blocks | No | Must be thread-local |
| JIT stacks | No | Must be thread-local |
| Compile contexts (read) | Yes | If never modified |
| Compile contexts (modify) | No | Copy before modifying |
| Match contexts (read) | Yes | If never modified |
| Match contexts (modify) | No | Copy before modifying |
| Deserialized pattern free | No | Shared table refcount race |
| POSIX wrapper | No | Do not use in MT code |
| Default contexts | Yes | Read-only |

## References

- PCRE2 Source: https://github.com/PCRE2Project/pcre2
- Documentation analyzed: `/tmp/pcre2/doc/pcre2api.3`, `/tmp/pcre2/doc/pcre2jit.3`, `/tmp/pcre2/doc/pcre2serialize.3`, `/tmp/pcre2/doc/pcre2posix.3`
- Source files analyzed: `pcre2_context.c`, `pcre2_compile.c`, `pcre2_jit_compile.c`, `pcre2_serialize.c`, `pcre2_posix.c`, `pcre2_match_data.c`
