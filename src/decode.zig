//! MC88100 instruction decoder and interpreter.
//!
//! Every encoding and semantic detail here is grounded in the Ghidra SLEIGH
//! specification for the m88k (m88k.slaspec). Field names match that spec:
//!
//!   op1        = bits 31..26  (primary opcode)
//!   d          = bits 25..21  (destination register / rD)
//!   s1r        = bits 20..16  (source register 1 / rS1)
//!   s2r        = bits  4..0   (source register 2 / rS2)
//!   imm16      = bits 15..0   (16-bit immediate)
//!   op11       = bits 15..5   (triadic sub-opcode)
//!   b5/m5      = bits 25..21  (bit number / condition mask)
//!   w5         = bits  9..5   (bit-field width)
//!   o5         = bits  4..0   (bit-field offset)
//!   vec9       = bits  8..0   (trap vector)
//!   d26        = bits 25..0   (signed branch displacement, in words)
//!
//! The MC88100 is big-endian. r0 always reads as zero. Double-word load/store
//! transfers a register pair (rD = most-significant word, rD+1 = least).

const std = @import("std");
const cpu_mod = @import("cpu.zig");
const Cpu = cpu_mod.Cpu;
const StepResult = cpu_mod.StepResult;

// --- Bit-field extraction helpers over the 32-bit instruction word ---

inline fn field(inst: u32, comptime hi: u5, comptime lo: u5) u32 {
    const width = hi - lo + 1;
    const mask: u32 = if (width == 32) 0xffffffff else (@as(u32, 1) << width) - 1;
    return (inst >> lo) & mask;
}

inline fn op1(inst: u32) u32 {
    return field(inst, 31, 26);
}
inline fn regD(inst: u32) u5 {
    return @intCast(field(inst, 25, 21));
}
inline fn regS1(inst: u32) u5 {
    return @intCast(field(inst, 20, 16));
}
inline fn regS2(inst: u32) u5 {
    return @intCast(field(inst, 4, 0));
}
inline fn imm16(inst: u32) u32 {
    return field(inst, 15, 0);
}
inline fn op11(inst: u32) u32 {
    return field(inst, 15, 5);
}

/// Sign-extend a value whose meaningful width is `bits`.
inline fn signExtend(value: u32, comptime bits: u6) u32 {
    const shift: u5 = @intCast(32 - @as(u6, bits));
    const s: i32 = @bitCast(value << shift);
    return @bitCast(s >> shift);
}

// --- Carry-aware arithmetic (matches the SLEIGH adduco/subuco macros) ---

/// a + b, returning result and unsigned carry-out of bit 31.
fn addCarry(a: u32, b: u32, carry_in: u1) struct { res: u32, carry: u1 } {
    const wide: u64 = @as(u64, a) + @as(u64, b) + @as(u64, carry_in);
    return .{ .res = @truncate(wide), .carry = @intCast((wide >> 32) & 1) };
}

/// m88k subtract: a + ~b + carry_in. Carry-out is the NOT-borrow flag.
fn subCarry(a: u32, b: u32, carry_in: u1) struct { res: u32, carry: u1 } {
    const wide: u64 = @as(u64, a) + @as(u64, ~b) + @as(u64, carry_in);
    return .{ .res = @truncate(wide), .carry = @intCast((wide >> 32) & 1) };
}

/// Signed add-overflow test: true when a + b does not fit in i32.
inline fn addSignedOverflows(a: u32, b: u32) bool {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return @addWithOverflow(sa, sb)[1] != 0;
}

/// Signed subtract-overflow test: true when a - b does not fit in i32.
inline fn subSignedOverflows(a: u32, b: u32) bool {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    return @subWithOverflow(sa, sb)[1] != 0;
}

/// Build the MC88100 `cmp` result bit-string. Bit layout from the SLEIGH spec:
///   11 hs(uns>=) 10 lo(uns<) 9 ls(uns<=) 8 hi(uns>)
///    7 ge(sgn>=)  6 lt(sgn<) 5 le(sgn<=) 4 gt(sgn>)  3 ne  2 eq
fn cmpResult(a: u32, b: u32) u32 {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    var r: u32 = 0;
    if (a >= b) r |= @as(u32, 1) << 11;
    if (a < b) r |= @as(u32, 1) << 10;
    if (a <= b) r |= @as(u32, 1) << 9;
    if (a > b) r |= @as(u32, 1) << 8;
    if (sa >= sb) r |= @as(u32, 1) << 7;
    if (sa < sb) r |= @as(u32, 1) << 6;
    if (sa <= sb) r |= @as(u32, 1) << 5;
    if (sa > sb) r |= @as(u32, 1) << 4;
    if (a != b) r |= @as(u32, 1) << 3;
    if (a == b) r |= @as(u32, 1) << 2;
    return r;
}

/// Build a `w`-bit mask at offset `o`. w==0 means a full 32-bit field.
fn bitfieldMask(w: u32, o: u32) u32 {
    const width = w & 0x1f;
    const base: u32 = if (width == 0) 0xffffffff else (~(@as(u32, 0xffffffff) << @intCast(width)));
    const off: u5 = @intCast(o & 0x1f);
    return base << off;
}

/// Unsigned bit-field extract: (v >> o) & mask(w).
fn bitfieldExtractU(v: u32, w: u32, o: u32) u32 {
    const width = w & 0x1f;
    const off: u5 = @intCast(o & 0x1f);
    const mask: u32 = if (width == 0) 0xffffffff else (~(@as(u32, 0xffffffff) << @intCast(width)));
    return (v >> off) & mask;
}

/// Signed bit-field extract: shift field to the top, arithmetic-shift back.
///
/// A width field of 0 encodes width 32 (`ext rD,rS1,0<o5>` extracts bits
/// [o5..31], i.e. an arithmetic right shift by o5). When `off + width` exceeds
/// 32 the field runs past bit 31, so only the bits actually present in the
/// register are used: the field's top is bit 31, `left` clamps to 0, and the
/// operation reduces to an arithmetic shift right by `off`. The earlier
/// `32 - width - off` computation underflowed (and panicked) in exactly this
/// common case; clamp instead.
fn bitfieldExtractS(v: u32, w: u32, o: u32) u32 {
    const width: u32 = if ((w & 0x1f) == 0) 32 else (w & 0x1f);
    const off = o & 0x1f;
    // Bits above the field (to the left of its MSB) once positioned at bit 31.
    // Clamp to 0 when the field reaches or passes bit 31.
    const left_u: u32 = if (off + width >= 32) 0 else 32 - width - off;
    const left: u5 = @intCast(left_u);
    // Arithmetic shift amount to right-justify with sign extension.
    const back: u5 = @intCast(left_u + off);
    const s: i32 = @bitCast(v << left);
    return @bitCast(s >> back);
}

/// Find the most-significant set bit (ff1): index 31..0, or 32 if value==0.
fn findFirstBitSet(value: u32) u32 {
    if (value == 0) return 32;
    return 31 - @clz(value);
}

/// Find the most-significant clear bit (ff0): 32 if value==0xffffffff.
fn findFirstBitClear(value: u32) u32 {
    return findFirstBitSet(~value);
}

/// Redirect control flow now (non-delayed): both pc-follow pointers move.
inline fn branchNow(cpu: *Cpu, target: u32) void {
    cpu.npc = target;
}

/// Schedule a delayed branch: the delay slot (current npc) executes first.
inline fn branchDelayed(cpu: *Cpu, target: u32) void {
    cpu.branch_pending = true;
    cpu.branch_target = target;
}

/// Execute exactly one instruction. Advances pc/npc, resolves any pending
/// delayed branch, and returns how the step affected control flow.
pub fn step(cpu: *Cpu) StepResult {
    if (cpu.halted) return .halted;

    if (cpu.instr_hook) |hook| hook(cpu.pc);

    const inst = cpu.read32(cpu.pc);
    cpu.ir = inst;
    cpu.ppc = cpu.pc;

    // Was a delayed branch scheduled by the *previous* instruction? If so, the
    // instruction we are about to execute is its delay slot; the transfer must
    // take effect after this one retires. Capture that intent now so branch
    // helpers in this step don't clobber it.
    const delayed_from_prev = cpu.branch_pending;
    const delayed_target = cpu.branch_target;
    cpu.branch_pending = false;

    // Default sequential flow for this instruction.
    cpu.npc = cpu.pc +% 4;

    const result = execute(cpu, inst);

    // Commit control flow. If the previous instruction armed a delayed branch,
    // its delay slot (the instruction we just ran) is complete, so jump to the
    // saved target -- unless this delay-slot instruction itself was a taken
    // branch, in which case the more recent transfer wins (rare, and undefined
    // on hardware; we honor the newer branch).
    if (delayed_from_prev and !cpu.branch_pending) {
        cpu.pc = delayed_target;
    } else {
        cpu.pc = cpu.npc;
    }

    return result;
}

/// Decode and execute a single instruction word. Returns the control-flow
/// effect. `cpu.pc` already points at the instruction being executed and
/// `cpu.npc` at the sequential successor when this is called.
fn execute(cpu: *Cpu, inst: u32) StepResult {
    const primary = op1(inst);

    switch (primary) {
        // ---- Immediate logical / arithmetic (op1 0x10..0x1f) ----
        0b010000 => setD(cpu, inst, cpu.getReg(regS1(inst)) & (0xffff0000 | imm16(inst))), // and
        0b010001 => setD(cpu, inst, cpu.getReg(regS1(inst)) & (0x0000ffff | (imm16(inst) << 16))), // and.u
        0b010010 => setD(cpu, inst, cpu.getReg(regS1(inst)) & imm16(inst)), // mask
        0b010011 => setD(cpu, inst, cpu.getReg(regS1(inst)) & (imm16(inst) << 16)), // mask.u
        0b010100 => setD(cpu, inst, cpu.getReg(regS1(inst)) ^ imm16(inst)), // xor
        0b010101 => setD(cpu, inst, cpu.getReg(regS1(inst)) ^ (imm16(inst) << 16)), // xor.u
        0b010110 => setD(cpu, inst, cpu.getReg(regS1(inst)) | imm16(inst)), // or
        0b010111 => setD(cpu, inst, cpu.getReg(regS1(inst)) | (imm16(inst) << 16)), // or.u

        0b011000 => setD(cpu, inst, cpu.getReg(regS1(inst)) +% imm16(inst)), // addu
        0b011001 => setD(cpu, inst, cpu.getReg(regS1(inst)) -% imm16(inst)), // subu
        0b011010 => divuOp(cpu, inst, cpu.getReg(regS1(inst)), imm16(inst)), // divu
        0b011011 => setD(cpu, inst, cpu.getReg(regS1(inst)) *% imm16(inst)), // mul
        0b011100 => addSignedOp(cpu, inst, cpu.getReg(regS1(inst)), imm16(inst)), // add
        0b011101 => subSignedOp(cpu, inst, cpu.getReg(regS1(inst)), imm16(inst)), // sub
        0b011110 => divSignedOp(cpu, inst, cpu.getReg(regS1(inst)), imm16(inst)), // div (signed)
        0b011111 => setD(cpu, inst, cmpResult(cpu.getReg(regS1(inst)), imm16(inst))), // cmp

        // ---- lda immediate forms (compute effective address) ----
        0b001100, 0b001101, 0b001110, 0b001111 => setD(cpu, inst, cpu.getReg(regS1(inst)) +% imm16(inst)),

        // ---- xmem (0x00,0x01), load (0x02,0x03,0x04-0x07), store (0x08-0x0b) ----
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b => return memImmediate(cpu, inst),

        // ---- Branches ----
        0b110000 => branchNow(cpu, brTarget(cpu, inst)), // br
        0b110001 => branchDelayed(cpu, brTarget(cpu, inst)), // br.n
        0b110010 => { // bsr
            cpu.setReg(1, cpu.npc);
            branchNow(cpu, brTarget(cpu, inst));
        },
        0b110011 => { // bsr.n
            cpu.setReg(1, brReturn(cpu, inst));
            branchDelayed(cpu, brTarget(cpu, inst));
        },
        0b110100 => bcondBit(cpu, inst, false, false), // bb0
        0b110101 => bcondBit(cpu, inst, false, true), // bb0.n
        0b110110 => bcondBit(cpu, inst, true, false), // bb1
        0b110111 => bcondBit(cpu, inst, true, true), // bb1.n
        0b111010 => bcnd(cpu, inst, false), // bcnd
        0b111011 => bcnd(cpu, inst, true), // bcnd.n

        // ---- Bit-field immediate + trap group (op1 0x3c) ----
        0b111100 => return group3c(cpu, inst),

        // ---- tbnd immediate: trap if unsigned(rS1) > IMM16 (op1 0x3e) ----
        0b111110 => {
            if (cpu.getReg(regS1(inst)) > imm16(inst)) {
                return raiseException(cpu, @intFromEnum(cpu_mod.Exception.bounds_check));
            }
        },

        // ---- Triadic register group (op1 0x3d) ----
        0b111101 => return group3d(cpu, inst),

        // ---- Control register / SFU1 group (op1 0x20, 0x21) ----
        0b100000 => group20(cpu, inst), // ldcr/stcr/xcr etc.
        0b100001 => {}, // SFU1 (FPU) - not yet implemented; treat as nop

        else => {
            // Unimplemented / illegal opcode: leave state, report normal for now.
        },
    }

    return .normal;
}

/// Write the destination register from an instruction's rD field.
inline fn setD(cpu: *Cpu, inst: u32, value: u32) void {
    cpu.setReg(regD(inst), value);
}

/// Unsigned divide. Raises Illegal Integer Divide (vector 8) on a zero
/// divisor; otherwise writes the quotient. Shared by immediate and register
/// forms. On a trap the destination register is left unchanged (manual 3-43).
fn divuOp(cpu: *Cpu, inst: u32, a: u32, b: u32) void {
    if (b == 0) {
        cpu.raiseException(@intFromEnum(cpu_mod.Exception.integer_divide));
        return;
    }
    setD(cpu, inst, a / b);
}

/// Signed divide. Raises Illegal Integer Divide (vector 8) when the divisor is
/// zero OR either operand is negative (MC88100 manual 3-42). Otherwise writes
/// the truncated quotient. On a trap the destination is left unchanged.
fn divSignedOp(cpu: *Cpu, inst: u32, a: u32, b: u32) void {
    const sa: i32 = @bitCast(a);
    const sb: i32 = @bitCast(b);
    if (b == 0 or sa < 0 or sb < 0) {
        cpu.raiseException(@intFromEnum(cpu_mod.Exception.integer_divide));
        return;
    }
    setD(cpu, inst, @bitCast(@divTrunc(sa, sb)));
}

/// Signed add. Raises Integer Overflow (vector 9) if the sum overflows i32;
/// the destination and carry are left unchanged in that case (manual 6.6).
fn addSignedOp(cpu: *Cpu, inst: u32, a: u32, b: u32) void {
    if (addSignedOverflows(a, b)) {
        cpu.raiseException(@intFromEnum(cpu_mod.Exception.integer_overflow));
        return;
    }
    setD(cpu, inst, a +% b);
}

/// Signed subtract. Raises Integer Overflow (vector 9) if the difference
/// overflows i32; destination and carry left unchanged in that case.
fn subSignedOp(cpu: *Cpu, inst: u32, a: u32, b: u32) void {
    if (subSignedOverflows(a, b)) {
        cpu.raiseException(@intFromEnum(cpu_mod.Exception.integer_overflow));
        return;
    }
    setD(cpu, inst, a -% b);
}

/// Compute a br/bsr target: pc + sign_extend(d26) * 4.
fn brTarget(cpu: *Cpu, inst: u32) u32 {
    const disp = signExtend(field(inst, 25, 0), 26);
    return cpu.pc +% (disp << 2);
}

/// Return address stored by bsr.n: the instruction after the delay slot.
fn brReturn(cpu: *Cpu, inst: u32) u32 {
    _ = inst;
    return cpu.pc +% 8;
}

/// bb0/bb1: branch if bit b5 of rS1 is clear (bb1==false) or set (bb1==true).
fn bcondBit(cpu: *Cpu, inst: u32, want_set: bool, delayed: bool) void {
    const bit: u5 = @intCast(field(inst, 25, 21));
    const s1 = cpu.getReg(regS1(inst));
    const is_set = ((s1 >> bit) & 1) != 0;
    const taken = if (want_set) is_set else !is_set;
    if (!taken) return;
    const disp = signExtend(imm16(inst), 16);
    const target = cpu.pc +% (disp << 2);
    if (delayed) branchDelayed(cpu, target) else branchNow(cpu, target);
}

/// Evaluate the m5 condition mask against rS1 compared with zero.
/// Condition source bits: 8=maxneg(0x80000000), 4=neg, 2=zero, 1=pos.
fn condHolds(mask: u32, s1: u32) bool {
    const si: i32 = @bitCast(s1);
    var src: u32 = 0;
    if (s1 == 0x80000000) src |= 8;
    if (si < 0 and s1 != 0x80000000) src |= 4;
    if (s1 == 0) src |= 2;
    if (si > 0) src |= 1;
    return (mask & src) != 0;
}

fn bcnd(cpu: *Cpu, inst: u32, delayed: bool) void {
    const mask = field(inst, 25, 21);
    const s1 = cpu.getReg(regS1(inst));
    if (!condHolds(mask, s1)) return;
    const disp = signExtend(imm16(inst), 16);
    const target = cpu.pc +% (disp << 2);
    if (delayed) branchDelayed(cpu, target) else branchNow(cpu, target);
}

/// Load/store and xmem with a zero-extended immediate index.
///
/// Dispatch is on the full primary opcode op1 (bits 31..26), matching the
/// SLEIGH encodings exactly:
///   0x00 xmem.bu   0x01 xmem (word)
///   0x02 ld.hu     0x03 ld.bu     0x04 ld.d         0x05 ld
///   0x06 ld.h      0x07 ld.b      (0x06/0x07 sign-extend)
///   0x08 st.d      0x09 st        0x0a st.h         0x0b st.b
/// (0x0c..0x0f lda immediate forms are handled directly in execute()).
/// The primary opcode itself selects signedness for sub-word loads:
/// 0x02/0x03 zero-extend (unsigned), 0x06/0x07 sign-extend.
fn memImmediate(cpu: *Cpu, inst: u32) StepResult {
    const primary = op1(inst);
    const s1 = cpu.getReg(regS1(inst));
    const ea = s1 +% imm16(inst);
    const d = regD(inst);

    switch (primary) {
        0x00 => { // xmem.bu
            const old = cpu.read8(ea);
            cpu.write8(ea, cpu.getReg(d));
            cpu.setReg(d, old);
        },
        0x01 => { // xmem (word)
            const old = cpu.read32(ea);
            cpu.write32(ea, cpu.getReg(d));
            cpu.setReg(d, old);
        },
        0x02 => cpu.setReg(d, cpu.read16(ea)), // ld.hu (zero-extend)
        0x03 => cpu.setReg(d, cpu.read8(ea)), // ld.bu (zero-extend)
        0x04 => { // ld.d (big-endian pair: rD = MS word, rD+1 = LS word)
            cpu.setReg(d, cpu.read32(ea));
            cpu.setReg(d +% 1, cpu.read32(ea +% 4));
        },
        0x05 => cpu.setReg(d, cpu.read32(ea)), // ld (word)
        0x06 => cpu.setReg(d, signExtend(cpu.read16(ea), 16)), // ld.h (signed)
        0x07 => cpu.setReg(d, signExtend(cpu.read8(ea), 8)), // ld.b (signed)
        0x08 => { // st.d (pair)
            cpu.write32(ea, cpu.getReg(d));
            cpu.write32(ea +% 4, cpu.getReg(d +% 1));
        },
        0x09 => cpu.write32(ea, cpu.getReg(d)), // st (word)
        0x0a => cpu.write16(ea, cpu.getReg(d) & 0xffff), // st.h
        0x0b => cpu.write8(ea, cpu.getReg(d) & 0xff), // st.b
        else => {},
    }
    return .normal;
}

/// op1 = 0x3c: bit-field immediate ops, plus tb0/tb1/tcnd/tbnd traps.
fn group3c(cpu: *Cpu, inst: u32) StepResult {
    const op6 = field(inst, 15, 10);
    const op7 = field(inst, 15, 9);
    const s1 = cpu.getReg(regS1(inst));
    const w5 = field(inst, 9, 5);
    const o5 = field(inst, 4, 0);

    // Trap-generating forms (op7 selects) come first.
    switch (op7) {
        0b1101100 => return trapOnBit(cpu, inst, true), // tb1
        0b1101000 => return trapOnBit(cpu, inst, false), // tb0
        0b1110100 => return trapOnCond(cpu, inst), // tcnd
        else => {},
    }

    switch (op6) {
        0b100000 => setD(cpu, inst, s1 & ~bitfieldMask(w5, o5)), // clr
        0b100010 => setD(cpu, inst, s1 | bitfieldMask(w5, o5)), // set
        0b100100 => setD(cpu, inst, bitfieldExtractS(s1, w5, o5)), // ext
        0b100110 => setD(cpu, inst, bitfieldExtractU(s1, w5, o5)), // extu
        0b101000 => { // mak
            const off: u5 = @intCast(o5 & 0x1f);
            setD(cpu, inst, (s1 << off) & bitfieldMask(w5, o5));
        },
        0b101010 => { // rot (rotate right by o5)
            const off: u5 = @intCast(o5 & 0x1f);
            const value = if (off == 0) s1 else (s1 >> off) | (s1 << @intCast(32 - @as(u32, off)));
            setD(cpu, inst, value);
        },
        else => {},
    }
    return .normal;
}

fn trapOnBit(cpu: *Cpu, inst: u32, want_set: bool) StepResult {
    const bit: u5 = @intCast(field(inst, 25, 21));
    const s1 = cpu.getReg(regS1(inst));
    const is_set = ((s1 >> bit) & 1) != 0;
    const fire = if (want_set) is_set else !is_set;
    if (!fire) return .normal;
    return raiseTrap(cpu, field(inst, 8, 0));
}

fn trapOnCond(cpu: *Cpu, inst: u32) StepResult {
    const mask = field(inst, 25, 21);
    const s1 = cpu.getReg(regS1(inst));
    if (!condHolds(mask, s1)) return .normal;
    return raiseTrap(cpu, field(inst, 8, 0));
}

/// Raise an architectural exception (integer divide, overflow, bounds check).
/// Delegates to the CPU, which notifies the host trap callback and vectors to
/// the handler unless the host reports it fully handled the exception. Returns
/// .trapped so the execute loop can react.
fn raiseException(cpu: *Cpu, vector: u32) StepResult {
    cpu.raiseException(vector);
    return .trapped;
}

/// A software trap instruction (tb0/tb1/tcnd) fired: transfer to the given
/// vector. Same mechanism as an architectural exception.
fn raiseTrap(cpu: *Cpu, vector: u32) StepResult {
    cpu.raiseException(vector);
    return .trapped;
}

/// op1 = 0x3d: triadic register-form instructions.
fn group3d(cpu: *Cpu, inst: u32) StepResult {
    const sub = op11(inst);
    const s1 = cpu.getReg(regS1(inst));
    const s2 = cpu.getReg(regS2(inst));
    const carryinout = field(inst, 9, 8);

    // Arithmetic with carry variants share op6 (bits 15..10); the carry mode is
    // in bits 9..8 and the low bits (7..5) must be zero.
    const op6 = field(inst, 15, 10);
    switch (op6) {
        0b011000 => { // addu (unsigned, never overflow-traps)
            arithCarry(cpu, inst, s1, s2, carryinout, .add);
            return .normal;
        },
        0b011001 => { // subu (unsigned, never overflow-traps)
            arithCarry(cpu, inst, s1, s2, carryinout, .sub);
            return .normal;
        },
        0b011100 => { // add (signed): overflow-traps on the plain form
            arithSigned(cpu, inst, s1, s2, carryinout, .add);
            return .normal;
        },
        0b011101 => { // sub (signed): overflow-traps on the plain form
            arithSigned(cpu, inst, s1, s2, carryinout, .sub);
            return .normal;
        },
        else => {},
    }

    switch (sub) {
        0b01101000000 => divuOp(cpu, inst, s1, s2), // divu
        0b01101100000 => setD(cpu, inst, s1 *% s2), // mul
        0b01111000000 => divSignedOp(cpu, inst, s1, s2), // div (signed)
        0b01111100000 => setD(cpu, inst, cmpResult(s1, s2)), // cmp

        0b01000000000 => setD(cpu, inst, s1 & s2), // and
        0b01000100000 => setD(cpu, inst, s1 & ~s2), // and.c
        0b01011000000 => setD(cpu, inst, s1 | s2), // or
        0b01011100000 => setD(cpu, inst, s1 | ~s2), // or.c
        0b01010000000 => setD(cpu, inst, s1 ^ s2), // xor
        0b01010100000 => setD(cpu, inst, s1 ^ ~s2), // xor.c

        // Bit-field register forms: width = bits 9..5 of s2, offset = bits 4..0.
        0b10000000000 => setD(cpu, inst, s1 & ~bitfieldMask((s2 >> 5) & 0x1f, s2 & 0x1f)), // clr
        0b10001000000 => setD(cpu, inst, s1 | bitfieldMask((s2 >> 5) & 0x1f, s2 & 0x1f)), // set
        0b10010000000 => setD(cpu, inst, bitfieldExtractS(s1, (s2 >> 5) & 0x1f, s2 & 0x1f)), // ext
        0b10011000000 => setD(cpu, inst, bitfieldExtractU(s1, (s2 >> 5) & 0x1f, s2 & 0x1f)), // extu
        0b10100000000 => { // mak
            const off: u5 = @intCast(s2 & 0x1f);
            setD(cpu, inst, (s1 << off) & bitfieldMask((s2 >> 5) & 0x1f, s2 & 0x1f));
        },
        0b10101000000 => { // rot
            const off: u5 = @intCast(s2 & 0x1f);
            const value = if (off == 0) s1 else (s1 >> off) | (s1 << @intCast(32 - @as(u32, off)));
            setD(cpu, inst, value);
        },

        0b11101000000 => setD(cpu, inst, findFirstBitSet(s2)), // ff1
        0b11101100000 => setD(cpu, inst, findFirstBitClear(s2)), // ff0

        0b11111000000 => { // tbnd rS1, rS2: trap if unsigned(s1) > unsigned(s2)
            if (s1 > s2) return raiseException(cpu, @intFromEnum(cpu_mod.Exception.bounds_check));
        },

        // lda scaled forms
        0b00110110000 => setD(cpu, inst, s1 +% s2 *% 4), // lda [scaled word]
        0b00110100000 => setD(cpu, inst, s1 +% s2), // lda (unscaled)
        0b00111110000 => setD(cpu, inst, s1 +% s2), // lda.b scaled
        0b00111100000 => setD(cpu, inst, s1 +% s2), // lda.b
        0b00111010000 => setD(cpu, inst, s1 +% s2 *% 2), // lda.h scaled
        0b00111000000 => setD(cpu, inst, s1 +% s2), // lda.h

        // Jumps
        0b11000000000 => branchNow(cpu, s2), // jmp
        0b11000100000 => branchDelayed(cpu, s2), // jmp.n
        0b11001000000 => { // jsr
            cpu.setReg(1, cpu.npc);
            branchNow(cpu, s2);
        },
        0b11001100000 => { // jsr.n
            cpu.setReg(1, cpu.pc +% 8);
            branchDelayed(cpu, s2);
        },

        0b11111100000 => { // rte - return from exception (supervisor)
            // Not modeled in user mode; treat as nop.
        },

        else => {
            // Register-form loads/stores and xmem live here too; dispatch them.
            return memRegister(cpu, inst);
        },
    }
    return .normal;
}

const ArithOp = enum { add, sub };

/// Handle addu/subu/add/sub with .ci/.co/.cio carry variants.
/// carryinout: 0b00 none, 0b10 carry-in, 0b01 carry-out, 0b11 both.
///
/// The plain (0b00) form is a straight add/subtract that neither reads nor
/// writes the carry flag. On the m88k, subtract is defined as s1 + ~s2 + 1, so
/// the plain subtract equals s1 - s2 with carry-in forced to 1; the carry-in
/// (.ci/.cio) variants substitute the actual carry flag for that +1.
fn arithCarry(cpu: *Cpu, inst: u32, s1: u32, s2: u32, carryinout: u32, comptime kind: ArithOp) void {
    const use_carry_in = (carryinout & 0b10) != 0;
    const update_carry_out = (carryinout & 0b01) != 0;

    const r = switch (kind) {
        .add => addCarry(s1, s2, if (use_carry_in) cpu.cf else 0),
        // For subtract the implicit +1 becomes the carry input; with .ci/.cio
        // the carry flag supplies it instead.
        .sub => subCarry(s1, s2, if (use_carry_in) cpu.cf else 1),
    };
    setD(cpu, inst, r.res);
    if (update_carry_out) cpu.cf = r.carry;
}

/// Signed add/sub (add/sub instructions, as opposed to addu/subu). The plain
/// form (carryinout=00) raises Integer Overflow when the signed result does
/// not fit in 32 bits, leaving rD and carry unchanged. The carry-bearing
/// variants (.ci/.co/.cio) are computed like the unsigned carry forms: the
/// bit pattern of the result is identical, and modelling their (rare) overflow
/// interaction with an incoming carry is deferred.
fn arithSigned(cpu: *Cpu, inst: u32, s1: u32, s2: u32, carryinout: u32, comptime kind: ArithOp) void {
    if (carryinout == 0b00) {
        switch (kind) {
            .add => addSignedOp(cpu, inst, s1, s2),
            .sub => subSignedOp(cpu, inst, s1, s2),
        }
        return;
    }
    arithCarry(cpu, inst, s1, s2, carryinout, kind);
}

/// Register-form load/store and xmem (op1 0x3d, op4 field selects the class).
fn memRegister(cpu: *Cpu, inst: u32) StepResult {
    // The instruction class is a 6-bit subopcode in bits 15..10 (the top of the
    // 11-bit SUBOPCODE field [15:5]; bits 8..5 are zero). Bit 9 selects the
    // scaled-index form. Verified against the MC88100 disassembler:
    //   0x00 xmem.bu  0x01 xmem      0x02 ld.hu   0x03 ld.bu
    //   0x04 ld.d     0x05 ld        0x06 ld.h    0x07 ld.b (signed)
    //   0x08 st.d     0x09 st        0x0a st.h    0x0b st.b
    //   0x0c lda.d    0x0d lda(word) 0x0e lda.h   0x0f lda.b
    // The lda* forms compute an effective address into rD without touching
    // memory (rD = rS1 + rS2 [* access-size when scaled]).
    const op6 = field(inst, 15, 10);
    const scaled = field(inst, 9, 9) != 0;
    const s1 = cpu.getReg(regS1(inst));
    const s2 = cpu.getReg(regS2(inst));
    const d = regD(inst);

    // Scaled index multiplies rS2 by the access size.
    const scale: u32 = switch (op6) {
        0x04, 0x08, 0x0c => 8, // double (ld.d/st.d/lda.d)
        0x01, 0x05, 0x09, 0x0d => 4, // word / xmem word / lda
        0x02, 0x06, 0x0a, 0x0e => 2, // half
        else => 1, // byte
    };
    const ea = if (scaled) s1 +% s2 *% scale else s1 +% s2;

    switch (op6) {
        0x00 => { // xmem.bu
            const old = cpu.read8(ea);
            cpu.write8(ea, cpu.getReg(d));
            cpu.setReg(d, old);
        },
        0x01 => { // xmem (word)
            const old = cpu.read32(ea);
            cpu.write32(ea, cpu.getReg(d));
            cpu.setReg(d, old);
        },
        0x02 => cpu.setReg(d, cpu.read16(ea)), // ld.hu
        0x03 => cpu.setReg(d, cpu.read8(ea)), // ld.bu
        0x04 => { // ld.d (register pair; rD = MS word, rD+1 = LS word)
            cpu.setReg(d, cpu.read32(ea));
            cpu.setReg(d +% 1, cpu.read32(ea +% 4));
        },
        0x05 => cpu.setReg(d, cpu.read32(ea)), // ld (word)
        0x06 => cpu.setReg(d, signExtend(cpu.read16(ea), 16)), // ld.h (signed)
        0x07 => cpu.setReg(d, signExtend(cpu.read8(ea), 8)), // ld.b (signed)
        0x08 => { // st.d (pair)
            cpu.write32(ea, cpu.getReg(d));
            cpu.write32(ea +% 4, cpu.getReg(d +% 1));
        },
        0x09 => cpu.write32(ea, cpu.getReg(d)), // st (word)
        0x0a => cpu.write16(ea, cpu.getReg(d) & 0xffff), // st.h
        0x0b => cpu.write8(ea, cpu.getReg(d) & 0xff), // st.b
        // lda* compute the (scaled) effective address into rD; no memory access.
        0x0c, 0x0d, 0x0e, 0x0f => cpu.setReg(d, ea),
        else => {},
    }
    return .normal;
}

/// op1 = 0x20: control-register moves (ldcr/stcr/xcr and FPU control variants).
/// Only the PSR-relevant subset is modeled; others read/write a placeholder.
fn group20(cpu: *Cpu, inst: u32) void {
    const op5 = field(inst, 15, 11);
    const crs = field(inst, 9, 5); // control register number
    switch (op5) {
        0b01000 => { // ldcr rD, crS
            setD(cpu, inst, readControl(cpu, crs));
        },
        0b10000 => { // stcr rS1, crS
            writeControl(cpu, crs, cpu.getReg(regS1(inst)));
        },
        0b11000 => { // xcr rD, rS1, crS
            const old = readControl(cpu, crs);
            writeControl(cpu, crs, cpu.getReg(regS1(inst)));
            setD(cpu, inst, old);
        },
        else => {},
    }
}

fn readControl(cpu: *Cpu, cr: u32) u32 {
    return switch (cr) {
        1 => cpu.psrWithCarry(), // cr1 = PSR
        else => 0,
    };
}

fn writeControl(cpu: *Cpu, cr: u32, value: u32) void {
    switch (cr) {
        1 => {
            cpu.psr = value;
            cpu.cf = @intCast((value >> Cpu.PSR_CARRY_BIT) & 1);
        },
        else => {},
    }
}
