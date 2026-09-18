//! C ABI surface for musashi88k, mirroring Musashi's exported-function model.
//!
//! The engine keeps a single global CPU context (as Musashi does), plus the
//! ability to save/restore contexts for multi-CPU setups. Host memory access
//! goes through the six global C functions the host must provide:
//!   m88k_read_memory_8/16/32, m88k_write_memory_8/16/32.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cpu_mod = @import("cpu.zig");
const decode = @import("decode.zig");

const Cpu = cpu_mod.Cpu;
const CpuType = cpu_mod.CpuType;

/// The active CPU context.
var g_cpu: Cpu = .{};

const ReadFn = *const fn (address: u32) callconv(.c) u32;
const WriteFn = *const fn (address: u32, value: u32) callconv(.c) void;

// ------------------------------------------------------------------------
// Host-provided memory callbacks. Two mechanisms, in priority order:
//
//  1. Runtime registration via m88k_set_memory_callbacks(). Portable across
//     static AND shared libraries on every target, because the engine never
//     needs to resolve a symbol that lives in the host executable.
//
//  2. The classic Musashi global functions m88k_read/write_memory_*. These are
//     resolved as WEAK externs so that a prebuilt shared library links on
//     macOS/Windows even when the host has not defined them; when the engine
//     is compiled into (or statically linked against) a program that DOES
//     define them, they are picked up automatically. If a weak global is
//     absent at runtime its pointer is null and the engine reports that the
//     bus is unconfigured rather than jumping to address zero.
// ------------------------------------------------------------------------

// Registered callbacks (mechanism 1). Null until the host registers them.
var g_reg_read8: ?ReadFn = null;
var g_reg_read16: ?ReadFn = null;
var g_reg_read32: ?ReadFn = null;
var g_reg_write8: ?WriteFn = null;
var g_reg_write16: ?WriteFn = null;
var g_reg_write32: ?WriteFn = null;

// Weak references to the classic global functions (mechanism 2), only compiled
// in when build_options.enable_global_callbacks is set (static library / source
// inclusion). A standalone shared library omits these entirely so it never
// depends on symbols that live in the host executable.
const globals = if (build_options.enable_global_callbacks) struct {
    extern fn m88k_read_memory_8(address: u32) callconv(.c) u32;
    extern fn m88k_read_memory_16(address: u32) callconv(.c) u32;
    extern fn m88k_read_memory_32(address: u32) callconv(.c) u32;
    extern fn m88k_write_memory_8(address: u32, value: u32) callconv(.c) void;
    extern fn m88k_write_memory_16(address: u32, value: u32) callconv(.c) void;
    extern fn m88k_write_memory_32(address: u32, value: u32) callconv(.c) void;

    fn bus() cpu_mod.MemoryBus {
        return .{
            .read8 = &m88k_read_memory_8,
            .read16 = &m88k_read_memory_16,
            .read32 = &m88k_read_memory_32,
            .write8 = &m88k_write_memory_8,
            .write16 = &m88k_write_memory_16,
            .write32 = &m88k_write_memory_32,
        };
    }
} else struct {};

/// Assemble the active memory bus. Registered callbacks take priority; if none
/// are registered and the global-function convenience is compiled in, fall back
/// to the host's global functions. Returns null if no full set is available.
fn resolveBus() ?cpu_mod.MemoryBus {
    if (g_reg_read8 != null and g_reg_read16 != null and g_reg_read32 != null and
        g_reg_write8 != null and g_reg_write16 != null and g_reg_write32 != null)
    {
        return .{
            .read8 = g_reg_read8.?,
            .read16 = g_reg_read16.?,
            .read32 = g_reg_read32.?,
            .write8 = g_reg_write8.?,
            .write16 = g_reg_write16.?,
            .write32 = g_reg_write32.?,
        };
    }
    if (build_options.enable_global_callbacks) {
        return globals.bus();
    }
    return null;
}

export fn m88k_set_memory_callbacks(
    read8: ?ReadFn,
    read16: ?ReadFn,
    read32: ?ReadFn,
    write8: ?WriteFn,
    write16: ?WriteFn,
    write32: ?WriteFn,
) callconv(.c) void {
    g_reg_read8 = read8;
    g_reg_read16 = read16;
    g_reg_read32 = read32;
    g_reg_write8 = write8;
    g_reg_write16 = write16;
    g_reg_write32 = write32;
    g_cpu.bus = resolveBus();
}

// ------------------------------------------------------------------------
// Register enum, matching the ordering in include/m88k.h exactly.
// ------------------------------------------------------------------------
const Reg = enum(c_int) {
    r0 = 0,
    // r1..r31 are 1..31
    pc = 32,
    npc = 33,
    ppc = 34,
    psr = 35,
    cf = 36,
    ir = 37,
    cpu_type = 38,
    _,
};

// ------------------------------------------------------------------------
// Core control functions.
// ------------------------------------------------------------------------

export fn m88k_set_cpu_type(cpu_type: u32) callconv(.c) void {
    g_cpu.cpu_type = switch (cpu_type) {
        1 => .mc88100,
        else => .invalid,
    };
}

export fn m88k_init() callconv(.c) void {
    // Preserve any callbacks registered before init.
    g_cpu = .{};
    g_cpu.cpu_type = .mc88100;
    g_cpu.bus = resolveBus();
}

export fn m88k_pulse_reset() callconv(.c) void {
    if (g_cpu.bus == null) g_cpu.bus = resolveBus();
    g_cpu.reset();
}

export fn m88k_execute(num_cycles: c_int) callconv(.c) c_int {
    g_cpu.cycles_requested = num_cycles;
    g_cpu.cycles_remaining = num_cycles;

    while (g_cpu.cycles_remaining > 0) {
        const result = decode.step(&g_cpu);
        // Each retired instruction costs (approximately) one cycle for now.
        g_cpu.cycles_remaining -= 1;
        if (result == .halted) break;
    }

    return g_cpu.cycles_requested - g_cpu.cycles_remaining;
}

export fn m88k_cycles_run() callconv(.c) c_int {
    return g_cpu.cycles_requested - g_cpu.cycles_remaining;
}

export fn m88k_cycles_remaining() callconv(.c) c_int {
    return g_cpu.cycles_remaining;
}

export fn m88k_modify_timeslice(cycles: c_int) callconv(.c) void {
    g_cpu.cycles_remaining = cycles;
}

export fn m88k_end_timeslice() callconv(.c) void {
    g_cpu.cycles_requested = g_cpu.cycles_requested - g_cpu.cycles_remaining;
    g_cpu.cycles_remaining = 0;
}

// ------------------------------------------------------------------------
// Callback setters.
// ------------------------------------------------------------------------

export fn m88k_set_instr_hook_callback(
    callback: ?*const fn (pc: u32) callconv(.c) void,
) callconv(.c) void {
    g_cpu.instr_hook = callback;
}

export fn m88k_set_trap_callback(
    callback: ?*const fn (vector: u32) callconv(.c) c_int,
) callconv(.c) void {
    g_cpu.trap_callback = callback;
}

// ------------------------------------------------------------------------
// Register access.
// ------------------------------------------------------------------------

fn readRegister(cpu: *const Cpu, reg: c_int) u32 {
    if (reg >= 0 and reg <= 31) {
        return cpu.getReg(@intCast(reg));
    }
    return switch (@as(Reg, @enumFromInt(reg))) {
        .pc => cpu.pc,
        .npc => cpu.npc,
        .ppc => cpu.ppc,
        .psr => cpu.psrWithCarry(),
        .cf => cpu.cf,
        .ir => cpu.ir,
        .cpu_type => @intFromEnum(cpu.cpu_type),
        else => 0,
    };
}

export fn m88k_get_reg(context: ?*anyopaque, reg: c_int) callconv(.c) u32 {
    const cpu: *const Cpu = if (context) |ctx|
        @ptrCast(@alignCast(ctx))
    else
        &g_cpu;
    return readRegister(cpu, reg);
}

export fn m88k_set_reg(reg: c_int, value: u32) callconv(.c) void {
    if (reg >= 0 and reg <= 31) {
        g_cpu.setReg(@intCast(reg), value);
        return;
    }
    switch (@as(Reg, @enumFromInt(reg))) {
        .pc => {
            g_cpu.pc = value;
            g_cpu.npc = value +% 4;
        },
        .npc => g_cpu.npc = value,
        .ppc => g_cpu.ppc = value,
        .psr => {
            g_cpu.psr = value;
            g_cpu.cf = @intCast((value >> Cpu.PSR_CARRY_BIT) & 1);
        },
        .cf => g_cpu.cf = @intCast(value & 1),
        .ir => g_cpu.ir = value,
        else => {},
    }
}

// ------------------------------------------------------------------------
// Context switching.
// ------------------------------------------------------------------------

export fn m88k_context_size() callconv(.c) u32 {
    return @sizeOf(Cpu);
}

export fn m88k_get_context(dst: ?*anyopaque) callconv(.c) u32 {
    if (dst) |d| {
        const p: *Cpu = @ptrCast(@alignCast(d));
        p.* = g_cpu;
    }
    return @sizeOf(Cpu);
}

export fn m88k_set_context(src: ?*anyopaque) callconv(.c) void {
    if (src) |s| {
        const p: *const Cpu = @ptrCast(@alignCast(s));
        g_cpu = p.*;
    }
}

// Keep the compiler from stripping exports when built as a static lib.
comptime {
    _ = m88k_init;
}
