//! Differential-test runner for musashi88k.
//!
//! Reads a JSON array of test cases from stdin, executes each one against the
//! MC88100 core in isolation, and writes a JSON array of results to stdout.
//! The companion driver (tests/difftest.py) feeds the SAME cases to the nono
//! hardware emulator via MCP and compares, so any semantic divergence between
//! this engine and real MC88100 silicon is caught mechanically.
//!
//! Input case shape (one object per instruction under test):
//!   {
//!     "name":  "addu.co carry out",
//!     "words": [4102185219],        // one or more instruction words (BE)
//!     "load":  16777216,            // base address the words are placed at
//!     "regs":  {"r2": 4294967295, "r3": 1},  // preset GPRs (r1..r31)
//!     "cf":    0,                    // preset carry flag (0/1)
//!     "steps": 1                     // instructions to single-step
//!   }
//!
//! Output result shape:
//!   {
//!     "name": "addu.co carry out",
//!     "regs": {"r0":0, "r1":..., ... "r31":...},  // all GPRs after stepping
//!     "cf":   1,
//!     "pc":   16777224
//!   }
//!
//! Memory model: a flat little array of RAM starting at the case's load
//! address, big-endian access, matching the MC88100. Loads/stores outside the
//! window wrap within it (tests keep addresses in range).

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decode = @import("decode.zig");
const Cpu = cpu_mod.Cpu;

// A flat RAM window. Big enough for code plus a scratch data area. The base
// address is set per-case; all accesses are taken modulo the window size, so
// tests should keep effective addresses within [load, load+RAM_SIZE).
const RAM_SIZE: u32 = 1 << 16; // 64 KiB
var g_ram: [RAM_SIZE]u8 = undefined;
var g_base: u32 = 0;

inline fn idx(a: u32) u32 {
    return (a -% g_base) & (RAM_SIZE - 1);
}

fn r8(a: u32) callconv(.c) u32 {
    return g_ram[idx(a)];
}
fn r16(a: u32) callconv(.c) u32 {
    const i = idx(a);
    return (@as(u32, g_ram[i]) << 8) | g_ram[(i + 1) & (RAM_SIZE - 1)];
}
fn r32(a: u32) callconv(.c) u32 {
    const i = idx(a);
    return (@as(u32, g_ram[i]) << 24) |
        (@as(u32, g_ram[(i + 1) & (RAM_SIZE - 1)]) << 16) |
        (@as(u32, g_ram[(i + 2) & (RAM_SIZE - 1)]) << 8) |
        g_ram[(i + 3) & (RAM_SIZE - 1)];
}
fn w8(a: u32, v: u32) callconv(.c) void {
    g_ram[idx(a)] = @truncate(v);
}
fn w16(a: u32, v: u32) callconv(.c) void {
    const i = idx(a);
    g_ram[i] = @truncate(v >> 8);
    g_ram[(i + 1) & (RAM_SIZE - 1)] = @truncate(v);
}
fn w32(a: u32, v: u32) callconv(.c) void {
    const i = idx(a);
    g_ram[i] = @truncate(v >> 24);
    g_ram[(i + 1) & (RAM_SIZE - 1)] = @truncate(v >> 16);
    g_ram[(i + 2) & (RAM_SIZE - 1)] = @truncate(v >> 8);
    g_ram[(i + 3) & (RAM_SIZE - 1)] = @truncate(v);
}

fn testBus() cpu_mod.MemoryBus {
    return .{ .read8 = r8, .read16 = r16, .read32 = r32, .write8 = w8, .write16 = w16, .write32 = w32 };
}

const Case = struct {
    name: []const u8 = "",
    words: []const u32 = &.{},
    load: u32 = 0x01000000,
    regs: std.json.ArrayHashMap(u32) = .{},
    cf: u1 = 0,
    steps: u32 = 1,
    // Optional preset memory: array of {addr, word} pairs written before run.
    mem: []const MemWord = &.{},
};

const MemWord = struct { addr: u32, word: u32 };

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    const dir = std.Io.Dir.cwd();

    // Args: difftest_runner <input.json> <output.json>
    var args = init.minimal.args.iterate();
    _ = args.next(); // program name
    const in_path = args.next() orelse return error.MissingInputPath;
    const out_path = args.next() orelse return error.MissingOutputPath;

    const input = try dir.readFileAlloc(io, in_path, alloc, .limited(16 * 1024 * 1024));
    defer alloc.free(input);

    const parsed = try std.json.parseFromSlice([]Case, alloc, input, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    try out.appendSlice(alloc, "[");
    for (parsed.value, 0..) |case, ci| {
        if (ci != 0) try out.appendSlice(alloc, ",");
        try runCase(alloc, &out, case);
    }
    try out.appendSlice(alloc, "]\n");

    try dir.writeFile(io, .{ .sub_path = out_path, .data = out.items });
}

fn runCase(alloc: std.mem.Allocator, out: *std.ArrayList(u8), case: Case) !void {
    @memset(&g_ram, 0);
    g_base = case.load;

    // Place the code words at the load address (big-endian).
    for (case.words, 0..) |word, i| {
        w32(case.load + @as(u32, @intCast(i * 4)), word);
    }
    // Apply any preset memory words.
    for (case.mem) |m| {
        w32(m.addr, m.word);
    }

    var c = Cpu{};
    c.bus = testBus();
    c.reset();
    c.pc = case.load;
    c.npc = case.load +% 4;
    c.cf = case.cf;

    // Preset registers. Keys are "r0".."r31".
    var it = case.regs.map.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len >= 2 and key[0] == 'r') {
            const n = std.fmt.parseInt(u5, key[1..], 10) catch continue;
            c.setReg(n, entry.value_ptr.*);
        }
    }

    var s: u32 = 0;
    while (s < case.steps) : (s += 1) {
        _ = decode.step(&c);
    }

    // Emit the result object. Case names in the fixtures are plain ASCII with
    // no JSON metacharacters, so the name is written verbatim between quotes.
    try out.appendSlice(alloc, "{\"name\":\"");
    try out.appendSlice(alloc, case.name);
    try out.appendSlice(alloc, "\",\"regs\":{");
    var i: u5 = 0;
    while (true) : (i += 1) {
        if (i != 0) try out.appendSlice(alloc, ",");
        try out.print(alloc, "\"r{d}\":{d}", .{ i, c.getReg(i) });
        if (i == 31) break;
    }
    try out.print(alloc, "}},\"cf\":{d},\"pc\":{d},\"exc\":{d}}}", .{ c.cf, c.pc, @as(i64, if (c.last_exception == Cpu.NO_EXCEPTION) -1 else @intCast(c.last_exception)) });
}
