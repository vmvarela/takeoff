//! Packager sub-modules.
//!
//! Each module exposes a `generate` function that writes a native package
//! format to disk without requiring any external tool.

pub const deb = @import("deb.zig");
pub const rpm = @import("rpm.zig");
