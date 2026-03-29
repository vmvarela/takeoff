# Changelog

All notable changes to this project will be documented in this file.

## [v0.1.0] - 2026-03-29

### Added

- Cross-compile binaries for Linux x86_64, macOS aarch64/x86_64, and Windows x86_64 from a single runner
- Parallel builds via `std.Io.Group` — all targets built concurrently
- `zr build` — cross-compile all targets and produce `.tar.gz` / `.zip` archives with checksums
- `zr verify` — verify SHA-256 and BLAKE3 checksums against a checksums file
- `zr release` — publish a GitHub Release via API and upload artifacts
- `zr check` — pre-flight validation: config, zig version, GITHUB_TOKEN, dry-run builds per target, optional tools
- JSONC config (`zr.jsonc`) with full support for targets, packages, and GitHub release settings
- Zero runtime dependencies: no libc, no OpenSSL, no libcurl — pure Zig stdlib
