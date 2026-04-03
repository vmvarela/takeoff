//! Packager sub-modules.
//!
//! Each module exposes a `generate` function that writes a native package
//! format to disk without requiring any external tool.

pub const deb = @import("deb.zig");
pub const rpm = @import("rpm.zig");
pub const apk = @import("apk.zig");
pub const homebrew = @import("homebrew.zig");
pub const scoop = @import("scoop.zig");
pub const winget = @import("winget.zig");
