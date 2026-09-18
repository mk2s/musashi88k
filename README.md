# musashi88k

A portable **Motorola MC88100** CPU emulation engine, written in Zig and exposing
a C ABI whose shape mirrors Karl Stenerud's [Musashi](https://github.com/kstenerud/Musashi)
m680x0 engine. It is intended as the CPU core for a user-mode syscall emulator
for MC88100-based machines (LUNA-88k, etc.).

- **Big-endian** MC88100 integer core.
- **32 general registers**, `r0` hardwired to zero.
- **Delayed branches** (`.n` forms) modeled per the MC88100 User's Manual: the
  delay-slot instruction always executes, then control transfers.
- **Musashi-style C API**: `m88k_init`, `m88k_pulse_reset`, `m88k_execute`,
  `m88k_get_reg` / `m88k_set_reg`, memory callbacks, context switching.
- Builds a **static** and **shared** library plus a C header, and
  cross-compiles to Linux, macOS, and Windows on x86-64 and aarch64.

## Status

Implemented (MC88100 integer/instruction unit, user mode):

- Arithmetic: `add(u)`, `sub(u)` with `.ci/.co/.cio` carry variants, `mul`,
  `div(u)`, `cmp` (result bit-string).
- Logical: `and(.c/.u)`, `or(.c/.u)`, `xor(.c/.u)`, `mask(.u)`.
- Bit-field: `clr`, `set`, `ext`, `extu`, `mak`, `rot` (immediate and register).
- Bit scan: `ff0`, `ff1`.
- Load/store: `ld(.b/.bu/.h/.hu/.d)`, `st(.b/.h/.d)`, `lda(.b/.h/.d)`,
  immediate / register / scaled indexing, big-endian double-word register pairs.
- Atomic: `xmem(.bu)`.
- Flow control: `br(.n)`, `bsr(.n)`, `bb0(.n)`, `bb1(.n)`, `bcnd(.n)`,
  `jmp(.n)`, `jsr(.n)`.
- Traps: `tb0`, `tb1`, `tcnd`, and `tbnd` (bounds check) via a host trap
  callback (the syscall hook).
- Architectural exceptions: signed `add`/`sub` raise **Integer Overflow**
  (vector 9); `div`/`divu` raise **Illegal Integer Divide** (vector 8) on a
  zero divisor, and signed `div` also on a negative operand; `tbnd` raises
  **Bounds Check** (vector 7). The destination register is left unchanged when
  an arithmetic exception fires, matching hardware.
- Control registers: `ldcr` / `stcr` / `xcr` for PSR (carry flag).

Deliberately stubbed for the current user-mode scope: the SFU1 floating-point
unit (`op1 = 0x21`), `rte`, and supervisor/MMU behavior.

## Building

Requires a recent Zig (verified with `0.17.0-dev.2163`, managed via
[zvm](https://www.zvm.app/); `build.zig` targets the 0.14+ build API).

```sh
zig build                 # native static + shared lib + header + smoke exe
zig build test            # build & run the C smoke test
zig build unit            # run the Zig decoder unit tests
zig build difftest        # run the differential suite against the oracle
zig build cross           # build static + shared libs for all six targets
zig build -Dtarget=aarch64-macos   # build for one specific target
```

Artifacts land in `zig-out/` (`lib/libm88k.a`, the shared library, and
`include/m88k.h`). `zig build cross` lays out per-target `static/` and
`shared/` subdirectories; a full `cross` run produces verified `.a`, `.so`,
`.dylib`, and Windows `.dll`/`.lib` artifacts for every target below.

Supported targets: `x86_64-linux-gnu`, `aarch64-linux-gnu`, `x86_64-macos`,
`aarch64-macos`, `x86_64-windows-gnu`, `aarch64-windows-gnu`.

## Wiring up memory

The engine needs to read and write your address space. There are two ways to
provide that, and they map onto the two library flavors.

### 1. Global functions (static library / source inclusion)

Define the six functions and link the **static** library. This is the classic
Musashi model.

```c
unsigned int m88k_read_memory_8 (unsigned int addr);
unsigned int m88k_read_memory_16(unsigned int addr);
unsigned int m88k_read_memory_32(unsigned int addr);
void m88k_write_memory_8 (unsigned int addr, unsigned int val);
void m88k_write_memory_16(unsigned int addr, unsigned int val);
void m88k_write_memory_32(unsigned int addr, unsigned int val);
```

### 2. Runtime registration (recommended for the shared library)

A prebuilt `.dylib` / `.dll` cannot reference symbols that live in your
executable, so register your callbacks at runtime instead:

```c
m88k_set_memory_callbacks(r8, r16, r32, w8, w16, w32);
```

Registered callbacks take priority over the global functions when both exist.

## Minimal usage

```c
#include "m88k.h"

int main(void) {
    m88k_init();
    m88k_set_cpu_type(M88K_CPU_TYPE_88100);
    /* register memory callbacks or define the globals ... */
    m88k_pulse_reset();          /* starts fetching at address 0 */
    m88k_execute(1000);          /* run ~1000 cycles */
    unsigned int r2 = m88k_get_reg(NULL, M88K_REG_R2);
    return (int)r2;
}
```

For a syscall emulator, install a trap handler and service traps in the host:

```c
static int on_trap(unsigned int vector) {
    /* inspect r2..r9 for syscall number/args, do the work, set r2 result */
    return 1; /* handled: continue past the faulting instruction */
}
m88k_set_trap_callback(on_trap);
```

The trap callback fires for both software traps (`tb0`/`tb1`/`tcnd`/`tbnd`) and
architectural exceptions (integer divide, integer overflow). Return non-zero to
tell the engine you fully handled it and execution should continue; return zero
(or install no callback) to let the engine vector to `VBR + vector*8` the way
hardware does.

## Differential testing against real MC88100 silicon

The tricky corners of the ISA (carry in/out on `add`/`sub`, the `cmp` result
bit-string, bit-field ops, divide/overflow traps) are validated against the
[nono](https://nonao.net/) LUNA-88k emulator used as a hardware oracle.

- `tests/encode.py` builds instruction words from the SLEIGH field layout; every
  word is round-tripped through nono's disassembler before use.
- `tests/difftest_cases.json` is the fixture (one instruction per case, with
  preset registers and carry).
- `tests/difftest_runner.zig` steps each case through this engine and emits the
  resulting registers, carry, and any exception vector as JSON.
- `tests/difftest_oracle.json` holds the expected results, gathered from nono via
  the `nono-mcp` `run_test_case` tool and confirmed against the User's Manual.
- `tests/difftest_compare.py` diffs the two.

Run the whole suite with:

```sh
zig build difftest        # runner + comparison against the oracle
```

The exception semantics above were found and fixed precisely because the oracle
disagreed with an earlier, naive implementation.

## References

The instruction semantics are grounded in:

- The Ghidra SLEIGH specification for the m88k (`m88k.slaspec`).
- The MC88100 User's Manual.
- The LLVM M88k backend target description.


