/* Smoke test for musashi88k: provides a flat big-endian memory, hand-assembles
 * a few MC88100 instructions, runs them, and checks register results.
 *
 * This exercises the full C ABI: the host memory callbacks, init/reset/execute,
 * and get/set_reg. It links against the static library built by build.zig.
 */

#include "m88k.h"
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define MEM_SIZE (1u << 20) /* 1 MiB */
static uint8_t g_mem[MEM_SIZE];

/* --- Host memory callbacks (big-endian) --- */
unsigned int m88k_read_memory_8(unsigned int a) {
    return g_mem[a & (MEM_SIZE - 1)];
}
unsigned int m88k_read_memory_16(unsigned int a) {
    a &= (MEM_SIZE - 1);
    return ((unsigned)g_mem[a] << 8) | g_mem[(a + 1) & (MEM_SIZE - 1)];
}
unsigned int m88k_read_memory_32(unsigned int a) {
    a &= (MEM_SIZE - 1);
    return ((unsigned)g_mem[a] << 24) |
           ((unsigned)g_mem[(a + 1) & (MEM_SIZE - 1)] << 16) |
           ((unsigned)g_mem[(a + 2) & (MEM_SIZE - 1)] << 8) |
           (unsigned)g_mem[(a + 3) & (MEM_SIZE - 1)];
}
void m88k_write_memory_8(unsigned int a, unsigned int v) {
    g_mem[a & (MEM_SIZE - 1)] = (uint8_t)v;
}
void m88k_write_memory_16(unsigned int a, unsigned int v) {
    a &= (MEM_SIZE - 1);
    g_mem[a] = (uint8_t)(v >> 8);
    g_mem[(a + 1) & (MEM_SIZE - 1)] = (uint8_t)v;
}
void m88k_write_memory_32(unsigned int a, unsigned int v) {
    a &= (MEM_SIZE - 1);
    g_mem[a] = (uint8_t)(v >> 24);
    g_mem[(a + 1) & (MEM_SIZE - 1)] = (uint8_t)(v >> 16);
    g_mem[(a + 2) & (MEM_SIZE - 1)] = (uint8_t)(v >> 8);
    g_mem[(a + 3) & (MEM_SIZE - 1)] = (uint8_t)v;
}

/* Store a big-endian instruction word at a byte address. */
static void put_word(unsigned int a, uint32_t w) {
    m88k_write_memory_32(a, w);
}

static int g_failures = 0;
static void check(const char *name, uint32_t got, uint32_t want) {
    if (got != want) {
        printf("  FAIL %-24s got=0x%08x want=0x%08x\n", name, got, want);
        g_failures++;
    } else {
        printf("  ok   %-24s = 0x%08x\n", name, got);
    }
}

int main(void) {
    printf("musashi88k smoke test\n");

    m88k_init();
    m88k_set_cpu_type(M88K_CPU_TYPE_88100);

    memset(g_mem, 0, sizeof(g_mem));

    /* Program at address 0:
     *   or   r2, r0, 0x1234      ; r2 = 0x1234           (or immediate)
     *   or.u r2, r2, 0x0000abcd  ; r2 |= 0xabcd0000 -> 0xabcd1234
     *   addu r3, r2, 0x1         ; r3 = r2 + 1 = 0xabcd1235
     *   subu r4, r3, r2 (reg)    ; r4 = r3 - r2 = 1
     * Encodings (from the SLEIGH spec):
     *   or   d,s1,imm16 : op1=010110
     *   or.u d,s1,imm16 : op1=010111
     *   addu d,s1,imm16 : op1=011000
     *   subu d,s1,s2    : op1=111101, op11=01101 -> subu reg has op6=011001
     */
    /* or r2, r0, 0x1234 : 010110 | d=00010 | s1=00000 | imm=0x1234 */
    put_word(0, (0x16u << 26) | (2u << 21) | (0u << 16) | 0x1234u);
    /* or.u r2, r2, 0xabcd : 010111 | d=00010 | s1=00010 | imm=0xabcd */
    put_word(4, (0x17u << 26) | (2u << 21) | (2u << 16) | 0xabcdu);
    /* addu r3, r2, 1 : 011000 | d=00011 | s1=00010 | imm=1 */
    put_word(8, (0x18u << 26) | (3u << 21) | (2u << 16) | 1u);
    /* subu r4, r3, r2 (register form): op1=111101, d=4, s1=3, op6=011001,
     * carryinout=00, leftover=000, s2=2.
     * Layout: op1[31:26]=111101, d[25:21]=00100, s1[20:16]=00011,
     *         op6[15:10]=011001, carryinout[9:8]=00, leftover[7:5]=000,
     *         s2[4:0]=00010 */
    put_word(12, (0x3Du << 26) | (4u << 21) | (3u << 16) |
                     (0x19u << 10) | (0u << 8) | (0u << 5) | 2u);

    m88k_pulse_reset();

    /* Reset sets pc=0, npc=4. Execute 4 instructions. */
    int used = m88k_execute(4);
    printf("cycles used: %d\n", used);

    check("r2", m88k_get_reg(NULL, M88K_REG_R2), 0xabcd1234u);
    check("r3", m88k_get_reg(NULL, M88K_REG_R3), 0xabcd1235u);
    check("r4", m88k_get_reg(NULL, M88K_REG_R4), 0x00000001u);
    check("r0 stays zero", m88k_get_reg(NULL, M88K_REG_R0), 0u);

    /* --- cmp result bitstring: compare 5 vs 3 (unsigned) --- */
    m88k_init();
    m88k_pulse_reset();
    m88k_set_reg(M88K_REG_R5, 5);
    m88k_set_reg(M88K_REG_R6, 3);
    /* cmp r7, r5, r6 (register): op1=111101, op11=01111100000 */
    put_word(0, (0x3Du << 26) | (7u << 21) | (5u << 16) | (0x3E0u << 0) | 6u);
    /* op11 (bits 15..5) = 0b01111100000 = 0x3E0; place it shifted into bits 15..5 */
    put_word(0, (0x3Du << 26) | (7u << 21) | (5u << 16) | (0x3E0u << 5) | 6u);
    m88k_set_reg(M88K_REG_PC, 0);
    m88k_execute(1);
    uint32_t cmp = m88k_get_reg(NULL, M88K_REG_R7);
    /* 5 > 3: expect hi(bit8), hs(bit11), ge(bit7), gt(bit4), ne(bit3) set. */
    printf("cmp(5,3) = 0x%08x\n", cmp);
    check("cmp ne bit", (cmp >> 3) & 1, 1);
    check("cmp gt bit", (cmp >> 4) & 1, 1);
    check("cmp eq bit", (cmp >> 2) & 1, 0);

    if (g_failures == 0) {
        printf("ALL SMOKE TESTS PASSED\n");
        return 0;
    }
    printf("%d SMOKE TEST(S) FAILED\n", g_failures);
    return 1;
}
