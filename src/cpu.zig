//! MC88100 CPU state and register file.
//!
//! The MC88100 is a big-endian 32-bit RISC core with 32 general registers
//! (r0 hardwired to zero) and a delayed-branch pipeline. This module holds the
//! architectural state and the host memory-callback plumbing; instruction
//! semantics live in `decode.zig`.

const std = @import("std");

/// Host memory access callbacks. These mirror Musashi's global read/write
/// functions; the C shim in `m88k.zig` wires the exported C symbols into here.
pub const MemoryBus = struct {
    read8: *const fn (address: u32) callconv(.c) u32,
    read16: *const fn (address: u32) callconv(.c) u32,
    read32: *const fn (address: u32) callconv(.c) u32,
    write8: *const fn (address: u32, value: u32) callconv(.c) void,
    write16: *const fn (address: u32, value: u32) callconv(.c) void,
    write32: *const fn (address: u32, value: u32) callconv(.c) void,
};

pub const CpuType = enum(u32) {
    invalid = 0,
    mc88100 = 1,
};

/// Result of stepping the core, so the execute loop can react to control flow.
pub const StepResult = enum {
    normal,
    trapped,
    halted,
};

/// MC88100 exception vector numbers (Table 6-1 in the User's Manual). The
/// exception is taken at address VBR + number*8. Only the ones an integer,
/// user-mode core can raise are enumerated; the rest are supervisor/FPU.
pub const Exception = enum(u32) {
    reset = 0,
    interrupt = 1,
    instruction_access = 2,
    data_access = 3,
    misaligned_access = 4,
    unimplemented_opcode = 5,
    privilege_violation = 6,
    bounds_check = 7,
    integer_divide = 8,
    integer_overflow = 9,
    error_exception = 10,
    // 114+ are the SFU/FPU precise/imprecise vectors; software traps (tb0/
    // tb1/tcnd/tbnd) supply their own vector number directly.
    _,
};

/// The architectural state of the MC88100 integer core.
///
/// Delayed branches: the 88100 fetches the instruction in the delay slot after
/// a `.n` branch before transferring control. We model this with `pc` (the
/// instruction being executed) and `npc` (the address of the next instruction
/// to fetch). A non-delayed branch sets both to the target. A delayed branch
/// lets the current `npc` (the delay slot) execute, then redirects.
pub const Cpu = struct {
    /// General registers. r[0] is kept at 0 at all times; writes are dropped
    /// at the write helper, but we still zero it defensively on reset.
    r: [32]u32 = @splat(0),

    /// Execution pointer: address of the instruction currently executing.
    pc: u32 = 0,
    /// Next-instruction pointer: address to fetch after the current one.
    npc: u32 = 0,
    /// Previous PC, for diagnostics / parity with m68k PPC.
    ppc: u32 = 0,

    /// Processor Status Register (cr1). Bit 28 is the carry flag on hardware.
    psr: u32 = 0,
    /// Carry flag, held separately for fast access and mirrored into PSR bit 28
    /// on demand. This matches the SLEIGH model, which breaks carry out of PSR
    /// into a dedicated 1-bit register.
    cf: u1 = 0,

    /// Last fetched instruction word (parity with m68k IR).
    ir: u32 = 0,

    cpu_type: CpuType = .mc88100,

    /// A pending delayed-branch target. When `branch_pending` is set, after the
    /// delay-slot instruction retires, control transfers to `branch_target`.
    branch_pending: bool = false,
    branch_target: u32 = 0,

    halted: bool = false,

    /// Cycle accounting for the current m88k_execute() timeslice.
    cycles_remaining: i32 = 0,
    cycles_requested: i32 = 0,

    bus: ?MemoryBus = null,
    instr_hook: ?*const fn (pc: u32) callconv(.c) void = null,
    trap_callback: ?*const fn (vector: u32) callconv(.c) c_int = null,

    /// Vector Base Register (cr7). Exceptions vector to vbr + number*8.
    vbr: u32 = 0,

    /// The vector number of the most recently raised exception (for tests and
    /// host inspection). 0xffffffff means "none since reset".
    last_exception: u32 = NO_EXCEPTION,

    /// PSR carry bit position on real hardware.
    pub const PSR_CARRY_BIT: u5 = 28;

    /// Sentinel for "no exception has been raised".
    pub const NO_EXCEPTION: u32 = 0xffffffff;

    pub fn reset(self: *Cpu) void {
        self.r = @splat(0);
        self.pc = 0;
        self.npc = 4;
        self.ppc = 0;
        self.psr = 0;
        self.cf = 0;
        self.ir = 0;
        self.vbr = 0;
        self.branch_pending = false;
        self.branch_target = 0;
        self.halted = false;
        self.last_exception = NO_EXCEPTION;
    }

    /// Raise an MC88100 exception. Records the vector, notifies the host trap
    /// callback (a syscall emulator services traps here), and redirects the
    /// pipeline to the exception handler at vbr + vector*8 UNLESS the host
    /// callback returns non-zero to indicate it fully handled the exception
    /// (in which case execution continues past the faulting instruction).
    ///
    /// Per the manual, the destination register and carry are left unchanged
    /// by an arithmetic exception; callers must raise BEFORE writing rD.
    pub fn raiseException(self: *Cpu, vector: u32) void {
        self.last_exception = vector;
        var handled = false;
        if (self.trap_callback) |cb| {
            handled = cb(vector) != 0;
        }
        if (!handled) {
            // Vector to the handler. A pending delayed branch is abandoned.
            self.branch_pending = false;
            const target = self.vbr +% (vector *% 8);
            self.npc = target;
        }
    }

    /// Read a general register, honoring the r0-is-zero rule.
    pub inline fn getReg(self: *const Cpu, index: u5) u32 {
        if (index == 0) return 0;
        return self.r[index];
    }

    /// Write a general register; writes to r0 are discarded.
    pub inline fn setReg(self: *Cpu, index: u5, value: u32) void {
        if (index == 0) return;
        self.r[index] = value;
    }

    /// Fold the standalone carry flag into the PSR value (bit 28).
    pub fn psrWithCarry(self: *const Cpu) u32 {
        const mask: u32 = @as(u32, 1) << PSR_CARRY_BIT;
        var v = self.psr & ~mask;
        if (self.cf != 0) v |= mask;
        return v;
    }

    // --- Memory helpers (big-endian, routed through the host bus) ---

    pub inline fn read8(self: *Cpu, address: u32) u32 {
        return self.bus.?.read8(address) & 0xff;
    }
    pub inline fn read16(self: *Cpu, address: u32) u32 {
        return self.bus.?.read16(address) & 0xffff;
    }
    pub inline fn read32(self: *Cpu, address: u32) u32 {
        return self.bus.?.read32(address);
    }
    pub inline fn write8(self: *Cpu, address: u32, value: u32) void {
        self.bus.?.write8(address, value & 0xff);
    }
    pub inline fn write16(self: *Cpu, address: u32, value: u32) void {
        self.bus.?.write16(address, value & 0xffff);
    }
    pub inline fn write32(self: *Cpu, address: u32, value: u32) void {
        self.bus.?.write32(address, value);
    }
};
