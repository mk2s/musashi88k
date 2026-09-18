//! musashi88k root module for Zig consumers.
//!
//! This is the convenience entry point for embedding the engine directly in a
//! Zig program: it re-exports the CPU state and the decoder/interpreter so you
//! can construct a `cpu.Cpu`, wire up a `cpu.MemoryBus`, and call
//! `decode.step()` without going through the C ABI.
//!
//! The C ABI surface lives in `m88k.zig` (the root source of the static/shared
//! library targets in build.zig). It depends on a `build_options` module that
//! the build system supplies, so it is intentionally NOT imported here; use the
//! built library and `include/m88k.h` to consume the engine from C.

pub const cpu = @import("cpu.zig");
pub const decode = @import("decode.zig");

pub const Cpu = cpu.Cpu;
pub const MemoryBus = cpu.MemoryBus;
pub const Exception = cpu.Exception;
pub const step = decode.step;

test {
    // Aggregate tests from the core modules.
    @import("std").testing.refAllDecls(@This());
    _ = @import("cpu.zig");
    _ = @import("decode.zig");
}
