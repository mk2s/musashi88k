/* ======================================================================== */
/* ============================= MUSASHI88K =============================== */
/* ======================================================================== */
/*
 *                                MUSASHI88K
 *                                Version 0.1.0
 *
 * A portable Motorola MC88100 processor emulation engine, written in Zig,
 * exposing a C ABI whose shape mirrors Karl Stenerud's Musashi (m68k) engine.
 *
 * The MC88100 is a big-endian 32-bit RISC processor. This engine models the
 * user-visible integer core: the 32 general registers (r0 hardwired to zero),
 * the program counter, the carry flag, delayed branches, and the load/store,
 * arithmetic, logical, bit-field, and flow-control instruction groups.
 *
 * API PARITY NOTE
 * ---------------
 * The function and enum naming follows Musashi's conventions so that code
 * written against Musashi maps mechanically onto this engine:
 *   m68k_init            -> m88k_init
 *   m68k_pulse_reset     -> m88k_pulse_reset
 *   m68k_execute         -> m88k_execute
 *   m68k_get_reg/set_reg -> m88k_get_reg/set_reg
 *   m68k_read_memory_*   -> m88k_read_memory_*
 *   m68k_write_memory_*  -> m88k_write_memory_*
 * The semantics differ where the architectures differ (RISC register file,
 * big-endian only, delayed branch slots).
 */

#ifndef MUSASHI88K__HEADER
#define MUSASHI88K__HEADER

#ifdef __cplusplus
extern "C" {
#endif

#ifndef FALSE
#define FALSE 0
#define TRUE 1
#endif

/* ======================================================================== */
/* ============================ GENERAL DEFINES =========================== */
/* ======================================================================== */

/* CPU types for use in m88k_set_cpu_type().
 * Only the MC88100 integer core is currently implemented; the enum leaves
 * room for the 88110 and CMMU-equipped variants.
 */
enum
{
    M88K_CPU_TYPE_INVALID,
    M88K_CPU_TYPE_88100
};

/* Registers used by m88k_get_reg() and m88k_set_reg(). */
typedef enum
{
    /* General registers r0..r31. r0 always reads as 0 and ignores writes. */
    M88K_REG_R0,
    M88K_REG_R1,
    M88K_REG_R2,
    M88K_REG_R3,
    M88K_REG_R4,
    M88K_REG_R5,
    M88K_REG_R6,
    M88K_REG_R7,
    M88K_REG_R8,
    M88K_REG_R9,
    M88K_REG_R10,
    M88K_REG_R11,
    M88K_REG_R12,
    M88K_REG_R13,
    M88K_REG_R14,
    M88K_REG_R15,
    M88K_REG_R16,
    M88K_REG_R17,
    M88K_REG_R18,
    M88K_REG_R19,
    M88K_REG_R20,
    M88K_REG_R21,
    M88K_REG_R22,
    M88K_REG_R23,
    M88K_REG_R24,
    M88K_REG_R25,
    M88K_REG_R26,
    M88K_REG_R27,
    M88K_REG_R28,
    M88K_REG_R29,
    M88K_REG_R30,
    M88K_REG_R31,

    /* Program counter and pipeline shadow.
     * The MC88100 has a delayed-branch pipeline. We model an execution pointer
     * (PC) and the next-instruction pointer (NPC); NPC is where a pending
     * delayed branch will land.
     */
    M88K_REG_PC,        /* Current execute pointer */
    M88K_REG_NPC,       /* Next instruction pointer (delay-slot target) */
    M88K_REG_PPC,       /* Previous value of the program counter */

    /* Control registers (supervisor-visible; a user-mode syscall emulator
     * generally only cares about PSR and the shadow set indirectly). */
    M88K_REG_PSR,       /* Processor Status Register (cr1) */
    M88K_REG_CF,        /* Carry flag (PSR bit 28), exposed directly */

    M88K_REG_IR,        /* Instruction register (last fetched opcode) */
    M88K_REG_CPU_TYPE   /* Type of CPU being run */
} m88k_register_t;

/* ======================================================================== */
/* ====================== FUNCTIONS CALLED BY THE CPU ===================== */
/* ======================================================================== */

/* You must implement these. They are the engine's window onto your address
 * space, exactly as in Musashi. Values are passed as 32-bit; for the 8- and
 * 16-bit variants only the low bits are meaningful. The MC88100 is big-endian,
 * so a 32-bit read at address A returns (mem[A]<<24)|(mem[A+1]<<16)|
 * (mem[A+2]<<8)|mem[A+3], and the engine assembles/decomposes multi-byte
 * accesses accordingly.
 */
unsigned int m88k_read_memory_8(unsigned int address);
unsigned int m88k_read_memory_16(unsigned int address);
unsigned int m88k_read_memory_32(unsigned int address);

void m88k_write_memory_8(unsigned int address, unsigned int value);
void m88k_write_memory_16(unsigned int address, unsigned int value);
void m88k_write_memory_32(unsigned int address, unsigned int value);

/* ------------------------------------------------------------------------ */
/* Callback registration (recommended for shared-library use).
 *
 * Two ways to give the engine access to memory:
 *
 *  (A) Global functions. Implement the six m88k_read/write_memory_* functions
 *      above and link the engine's SOURCE or STATIC library into your program.
 *      This mirrors Musashi's original model and works when the final link can
 *      resolve those globals.
 *
 *  (B) Runtime registration. Call m88k_set_memory_callbacks() with your own
 *      function pointers. This is the portable choice for a prebuilt SHARED
 *      library (.dylib/.dll), where the engine cannot depend on symbols that
 *      live in the host executable. If any pointer is registered, the engine
 *      uses the registered callbacks in preference to the globals.
 *
 * Pass NULL for any individual pointer to leave it unset. Passing all NULLs
 * clears the registration and reverts to the global functions.
 */
typedef unsigned int (*m88k_read_fn)(unsigned int address);
typedef void (*m88k_write_fn)(unsigned int address, unsigned int value);

void m88k_set_memory_callbacks(
    m88k_read_fn read8,
    m88k_read_fn read16,
    m88k_read_fn read32,
    m88k_write_fn write8,
    m88k_write_fn write16,
    m88k_write_fn write32);

/* ======================================================================== */
/* ============================== CALLBACKS =============================== */
/* ======================================================================== */

/* Called just before each opcode fetch (parity with m68k_set_instr_hook_callback).
 * Pass NULL to disable. */
void m88k_set_instr_hook_callback(void (*callback)(unsigned int pc));

/* Called when the CPU executes a trap instruction (tb0/tb1/tcnd/tbnd or an
 * explicit trap). The callback receives the trap vector number. Return TRUE if
 * the host handled it (e.g. serviced a syscall) and execution should continue
 * past the trap; return FALSE to let the engine take the default action.
 * Pass NULL to disable (default action is taken). This is the primary hook a
 * syscall emulator uses. */
void m88k_set_trap_callback(int (*callback)(unsigned int vector));

/* ======================================================================== */
/* ====================== FUNCTIONS TO ACCESS THE CPU ===================== */
/* ======================================================================== */

/* Select the CPU variant to emulate. Defaults to M88K_CPU_TYPE_88100. */
void m88k_set_cpu_type(unsigned int cpu_type);

/* Initialize the engine. Call once before first use. */
void m88k_init(void);

/* Pulse the RESET pin. You MUST reset at least once before executing.
 * On reset the MC88100 begins fetching at address 0. */
void m88k_pulse_reset(void);

/* Execute up to num_cycles worth of instructions. Returns the number of
 * cycles actually consumed. (The 88100 integer core issues most instructions
 * in one cycle; timing is approximate for now.) */
int m88k_execute(int num_cycles);

/* Timeslice management, matching Musashi. */
int m88k_cycles_run(void);         /* cycles run so far in current execute */
int m88k_cycles_remaining(void);   /* cycles left in current execute */
void m88k_modify_timeslice(int cycles);
void m88k_end_timeslice(void);

/* Read/modify CPU registers. If context is NULL the running context is used,
 * matching m68k_get_reg's convention. */
unsigned int m88k_get_reg(void *context, m88k_register_t reg);
void m88k_set_reg(m88k_register_t reg, unsigned int value);

/* ======================================================================== */
/* ========================== CONTEXT SWITCHING ========================== */
/* ======================================================================== */

/* Size of a saved CPU context in bytes. */
unsigned int m88k_context_size(void);

/* Copy the current context into dst. Returns the number of bytes written. */
unsigned int m88k_get_context(void *dst);

/* Make the context pointed to by src the current one. */
void m88k_set_context(void *src);

#ifdef __cplusplus
}
#endif

#endif /* MUSASHI88K__HEADER */
