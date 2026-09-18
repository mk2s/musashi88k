//! Zig-level unit tests for the MC88100 decoder. These drive the Cpu struct
//! directly with a small in-process memory, independent of the C ABI layer.

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const decode = @import("decode.zig");
const Cpu = cpu_mod.Cpu;

// A flat big-endian memory shared by the test bus callbacks.
var mem: [4096]u8 = undefined;

fn r8(a: u32) callconv(.c) u32 {
    return mem[a & 0xfff];
}
fn r16(a: u32) callconv(.c) u32 {
    const i = a & 0xfff;
    return (@as(u32, mem[i]) << 8) | mem[(i + 1) & 0xfff];
}
fn r32(a: u32) callconv(.c) u32 {
    const i = a & 0xfff;
    return (@as(u32, mem[i]) << 24) | (@as(u32, mem[(i + 1) & 0xfff]) << 16) |
        (@as(u32, mem[(i + 2) & 0xfff]) << 8) | mem[(i + 3) & 0xfff];
}
fn w8(a: u32, v: u32) callconv(.c) void {
    mem[a & 0xfff] = @truncate(v);
}
fn w16(a: u32, v: u32) callconv(.c) void {
    const i = a & 0xfff;
    mem[i] = @truncate(v >> 8);
    mem[(i + 1) & 0xfff] = @truncate(v);
}
fn w32(a: u32, v: u32) callconv(.c) void {
    const i = a & 0xfff;
    mem[i] = @truncate(v >> 24);
    mem[(i + 1) & 0xfff] = @truncate(v >> 16);
    mem[(i + 2) & 0xfff] = @truncate(v >> 8);
    mem[(i + 3) & 0xfff] = @truncate(v);
}

fn testBus() cpu_mod.MemoryBus {
    return .{ .read8 = r8, .read16 = r16, .read32 = r32, .write8 = w8, .write16 = w16, .write32 = w32 };
}

fn freshCpu() Cpu {
    @memset(&mem, 0);
    var c = Cpu{};
    c.bus = testBus();
    c.reset();
    return c;
}

fn putWord(a: u32, word: u32) void {
    w32(a, word);
}

test "or immediate then or.u builds a 32-bit constant" {
    var c = freshCpu();
    putWord(0, (0x16 << 26) | (2 << 21) | (0 << 16) | 0x1234); // or r2,r0,0x1234
    putWord(4, (0x17 << 26) | (2 << 21) | (2 << 16) | 0xabcd); // or.u r2,r2,0xabcd
    _ = decode.step(&c);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 0xabcd1234), c.getReg(2));
}

test "r0 is hardwired to zero" {
    var c = freshCpu();
    putWord(0, (0x18 << 26) | (0 << 21) | (0 << 16) | 0x5555); // addu r0,r0,0x5555
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 0), c.getReg(0));
}

test "addu carry-out sets CF" {
    var c = freshCpu();
    c.setReg(2, 0xffffffff);
    c.setReg(3, 1);
    // addu.co r4, r2, r3 : op1=0x3d, op6=011000, carryinout=01
    putWord(0, (0x3d << 26) | (4 << 21) | (2 << 16) | (0x18 << 10) | (0b01 << 8) | 3);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 0), c.getReg(4));
    try std.testing.expectEqual(@as(u1, 1), c.cf);
}

test "cmp produces the expected result bitstring for 5 vs 3" {
    var c = freshCpu();
    c.setReg(5, 5);
    c.setReg(6, 3);
    // cmp r7, r5, r6 : op1=0x3d, op11=0b01111100000
    putWord(0, (0x3d << 26) | (7 << 21) | (5 << 16) | (0x3E0 << 5) | 6);
    _ = decode.step(&c);
    const v = c.getReg(7);
    try std.testing.expect((v >> 3) & 1 == 1); // ne
    try std.testing.expect((v >> 4) & 1 == 1); // gt (signed)
    try std.testing.expect((v >> 8) & 1 == 1); // hi (unsigned >)
    try std.testing.expect((v >> 2) & 1 == 0); // eq clear
}

test "ld/st word round trip, big-endian" {
    var c = freshCpu();
    c.setReg(2, 0x100); // base address
    c.setReg(3, 0xdeadbeef); // value to store
    // st r3, r2, 0 : op1=0x09
    putWord(0, (0x09 << 26) | (3 << 21) | (2 << 16) | 0);
    // ld r4, r2, 0 : op1=0x05
    putWord(4, (0x05 << 26) | (4 << 21) | (2 << 16) | 0);
    _ = decode.step(&c);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), c.getReg(4));
    // Verify big-endian byte order in memory.
    try std.testing.expectEqual(@as(u8, 0xde), mem[0x100]);
    try std.testing.expectEqual(@as(u8, 0xef), mem[0x103]);
}

test "delayed branch executes the delay slot" {
    var c = freshCpu();
    // br.n +4 (skip to pc+? ) ; delay slot: addu r2,r0,7 ; target: addu r3,r0,9
    // br.n disp: target = pc + disp*4. At pc=0, disp=2 -> target = 8.
    putWord(0, (0x31 << 26) | 2); // br.n +2 -> target 8
    putWord(4, (0x18 << 26) | (2 << 21) | (0 << 16) | 7); // delay slot: r2 = 7
    putWord(8, (0x18 << 26) | (3 << 21) | (0 << 16) | 9); // target: r3 = 9
    _ = decode.step(&c); // executes br.n, schedules branch
    _ = decode.step(&c); // executes delay slot (r2=7), then branch takes effect
    try std.testing.expectEqual(@as(u32, 7), c.getReg(2));
    _ = decode.step(&c); // should execute target r3=9
    try std.testing.expectEqual(@as(u32, 9), c.getReg(3));
}

test "bit-field extu extracts an unsigned field" {
    var c = freshCpu();
    c.setReg(2, 0xabcdef12);
    // extu r3, r2, 8<4> : width=8, offset=4. op1=0x3c, op6=100110
    putWord(0, (0x3c << 26) | (3 << 21) | (2 << 16) | (0x26 << 10) | (8 << 5) | 4);
    _ = decode.step(&c);
    // (0xabcdef12 >> 4) & 0xff = 0xf1
    try std.testing.expectEqual(@as(u32, 0xf1), c.getReg(3));
}

test "div by zero raises integer-divide exception and leaves rD unchanged" {
    var c = freshCpu();
    c.setReg(2, 100);
    c.setReg(3, 0);
    c.setReg(4, 123); // sentinel: must be preserved on trap
    // divu r4, r2, r3 : op1=0x3d, op11=0b01101000000
    putWord(0, (0x3d << 26) | (4 << 21) | (2 << 16) | (0x340 << 5) | 3);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 123), c.getReg(4));
    try std.testing.expectEqual(@as(u32, 8), c.last_exception);
}

test "signed div with a negative operand traps (vector 8)" {
    var c = freshCpu();
    c.setReg(2, @bitCast(@as(i32, -100)));
    c.setReg(3, 7);
    c.setReg(4, 123);
    // div r4, r2, r3 : op1=0x3d, op11=0b01111000000
    putWord(0, (0x3d << 26) | (4 << 21) | (2 << 16) | (0x3c0 << 5) | 3);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 123), c.getReg(4));
    try std.testing.expectEqual(@as(u32, 8), c.last_exception);
}

test "signed add overflow raises integer-overflow exception (vector 9)" {
    var c = freshCpu();
    c.setReg(2, 0x7fffffff);
    c.setReg(3, 1);
    c.setReg(4, 123);
    // add r4, r2, r3 : op1=0x3d, op6=011100, carryinout=00
    putWord(0, (0x3d << 26) | (4 << 21) | (2 << 16) | (0x1c << 10) | 3);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 123), c.getReg(4));
    try std.testing.expectEqual(@as(u32, 9), c.last_exception);
}

test "addu never overflow-traps" {
    var c = freshCpu();
    c.setReg(2, 0x7fffffff);
    c.setReg(3, 1);
    // addu r4, r2, r3 : op1=0x3d, op6=011000, carryinout=00
    putWord(0, (0x3d << 26) | (4 << 21) | (2 << 16) | (0x18 << 10) | 3);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 0x80000000), c.getReg(4));
    try std.testing.expectEqual(Cpu.NO_EXCEPTION, c.last_exception);
}

test "tbnd immediate traps when index exceeds bound (vector 7)" {
    var c = freshCpu();
    c.setReg(2, 100);
    // tbnd r2, 50 : op1=0b111110, s1=r2, imm16=50
    putWord(0, (0x3e << 26) | (0 << 21) | (2 << 16) | 50);
    _ = decode.step(&c);
    try std.testing.expectEqual(@as(u32, 7), c.last_exception);
}

test "tbnd immediate does not trap when in bounds" {
    var c = freshCpu();
    c.setReg(2, 10);
    putWord(0, (0x3e << 26) | (0 << 21) | (2 << 16) | 50);
    _ = decode.step(&c);
    try std.testing.expectEqual(Cpu.NO_EXCEPTION, c.last_exception);
}
