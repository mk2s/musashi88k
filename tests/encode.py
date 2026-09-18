#!/usr/bin/env python3
"""MC88100 instruction encoder for the differential-test fixtures.

Field layout (from the Ghidra SLEIGH spec, bit 31 = MSB):
  op1  = bits 31..26   d = bits 25..21   s1 = bits 20..16
  imm16 = bits 15..0   op6 = bits 15..10  carryinout = bits 9..8
  op11 = bits 15..5    s2 = bits 4..0     w5 = bits 9..5  o5 = bits 4..0

We build words for exactly the instruction forms the sweep exercises and print
them as decimal so they can be dropped into JSON fixtures. Every word is meant
to be round-tripped through nono's disassembler before use.
"""

def word(op1, d=0, s1=0, low16=0):
    return ((op1 & 0x3f) << 26) | ((d & 0x1f) << 21) | ((s1 & 0x1f) << 16) | (low16 & 0xffff)

# --- Triadic register form (op1 = 0x3d): op6 in 15..10, carryinout 9..8, s2 4..0
def triadic(d, s1, s2, op6, cio=0, leftover=0):
    low16 = ((op6 & 0x3f) << 10) | ((cio & 0x3) << 8) | ((leftover & 0x7) << 5) | (s2 & 0x1f)
    return word(0x3d, d, s1, low16)

# Triadic with a full 11-bit op11 (15..5) sub-opcode, s2 in 4..0
def triadic11(d, s1, s2, op11):
    low16 = ((op11 & 0x7ff) << 5) | (s2 & 0x1f)
    return word(0x3d, d, s1, low16)

# op6 values for the arithmetic-with-carry family
OP6 = {"addu":0b011000, "subu":0b011001, "add":0b011100, "sub":0b011101}
# carryinout: none=00, ci=10, co=01, cio=11
CIO = {"":0b00, ".ci":0b10, ".co":0b01, ".cio":0b11}

# op11 values for other triadic ops
OP11 = {
    "divu":0b01101000000, "mul":0b01101100000, "div":0b01111000000, "cmp":0b01111100000,
    "and":0b01000000000, "and.c":0b01000100000, "or":0b01011000000, "or.c":0b01011100000,
    "xor":0b01010000000, "xor.c":0b01010100000,
    "ff1":0b11101000000, "ff0":0b11101100000,
}

# op6 for the 0x3c bit-field immediate group
OP6_BF = {"clr":0b100000, "set":0b100010, "ext":0b100100, "extu":0b100110, "mak":0b101000, "rot":0b101010}

def arith(mnem, suffix, d, s1, s2):
    return triadic(d, s1, s2, OP6[mnem], CIO[suffix])

def op11instr(mnem, d, s1, s2):
    return triadic11(d, s1, s2, OP11[mnem])

def bitfield_imm(mnem, d, s1, w5, o5):
    low16 = ((OP6_BF[mnem] & 0x3f) << 10) | ((w5 & 0x1f) << 5) | (o5 & 0x1f)
    return word(0x3c, d, s1, low16)

# Immediate-form arithmetic/logical (op1 selects the op)
OP1_IMM = {
    "and":0x10, "and.u":0x11, "mask":0x12, "mask.u":0x13,
    "xor":0x14, "xor.u":0x15, "or":0x16, "or.u":0x17,
    "addu":0x18, "subu":0x19, "divu":0x1a, "mul":0x1b,
    "add":0x1c, "sub":0x1d, "div":0x1e, "cmp":0x1f,
}
def imm(mnem, d, s1, imm16):
    return word(OP1_IMM[mnem], d, s1, imm16 & 0xffff)

# Immediate loads/stores (op1 encodes size+sign)
OP1_LS = {
    "ld.d":0x04, "ld":0x05, "ld.h":0x06, "ld.hu":0x06, "ld.b":0x07, "ld.bu":0x07,
    "st.d":0x08, "st":0x09, "st.h":0x0a, "st.b":0x0b,
}
# For ld.h/ld.b the sign bit lives in bits 29..28 (01 signed, 00 unsigned);
# op1 already carries it via 0x06/0x07 with the P bit. We keep it simple and
# emit the exact op1 the SLEIGH spec lists for each mnemonic.

if __name__ == "__main__":
    import json, sys
    # A registry of named encodings the sweep uses.
    reg = {}
    reg["addu.co r4,r2,r3"] = arith("addu", ".co", 4, 2, 3)
    reg["addu.cio r4,r2,r3"] = arith("addu", ".cio", 4, 2, 3)
    reg["addu.ci r4,r2,r3"] = arith("addu", ".ci", 4, 2, 3)
    reg["subu.co r4,r2,r3"] = arith("subu", ".co", 4, 2, 3)
    reg["subu.cio r4,r2,r3"] = arith("subu", ".cio", 4, 2, 3)
    reg["subu r4,r2,r3"] = arith("subu", "", 4, 2, 3)
    reg["cmp r7,r5,r6"] = op11instr("cmp", 7, 5, 6)
    reg["divu r4,r2,r3"] = op11instr("divu", 4, 2, 3)
    reg["div r4,r2,r3"] = op11instr("div", 4, 2, 3)
    reg["mul r4,r2,r3"] = op11instr("mul", 4, 2, 3)
    reg["ff1 r4,r3"] = op11instr("ff1", 4, 0, 3)
    reg["ff0 r4,r3"] = op11instr("ff0", 4, 0, 3)
    reg["and.c r4,r2,r3"] = op11instr("and.c", 4, 2, 3)
    reg["or.c r4,r2,r3"] = op11instr("or.c", 4, 2, 3)
    reg["xor.c r4,r2,r3"] = op11instr("xor.c", 4, 2, 3)
    reg["extu r4,r2,8<4>"] = bitfield_imm("extu", 4, 2, 8, 4)
    reg["ext r4,r2,8<4>"] = bitfield_imm("ext", 4, 2, 8, 4)
    reg["clr r4,r2,8<4>"] = bitfield_imm("clr", 4, 2, 8, 4)
    reg["set r4,r2,8<4>"] = bitfield_imm("set", 4, 2, 8, 4)
    reg["mak r4,r2,8<4>"] = bitfield_imm("mak", 4, 2, 8, 4)
    reg["rot r4,r2,<4>"] = bitfield_imm("rot", 4, 2, 0, 4)
    for name, w in reg.items():
        print(f"{w}\t0x{w:08x}\t{name}")
