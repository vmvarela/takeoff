# AGENTS.md — AI Coding Assistant Guide for zr

## Project overview

`zr` is a release automation tool for Zig projects. It cross-compiles binaries for all targets on a single Linux runner, then packages them into native formats for each OS/distribution.

## Repository structure

- `src/` — all Zig source code
- `src/packagers/` — one file per package format (.deb, .rpm, etc.)
- `src/publishers/` — GitHub, AUR, Homebrew tap publishers
- `build.zig` — the project build file
- `zr.jsonc` — zr's own release config (dogfooding)

## Key constraints

- Minimum Zig version: 0.14.0
- Zero runtime dependencies — no libc, no OpenSSL, no libcurl
- All package formats must be generatable from Linux
- std.crypto for all hashing (SHA-256, BLAKE3)
- std.http for all HTTP — no libcurl
- Parallel builds via std.Thread.Pool

## Code style

- Follow the Zig standard style (zig fmt enforced in CI)
- Prefer explicit error handling over unreachable
- Each packager in src/packagers/ must implement the Packager interface
- All public functions must have a doc comment

## Testing

- `zig build test` runs all unit tests
- Integration tests live in `test/` and require a real `zig` binary in PATH
- Every packager must have at least one test that generates a valid package and validates its structure

## When implementing a packager

1. Read the format spec (linked in the issue)
2. Implement in `src/packagers/{format}.zig`
3. Expose `pub fn generate(config: Config, artifacts: []Artifact) !void`
4. Add unit tests for the generated file structure
5. Validate with the native tool if available (dpkg-deb, rpm, apk, etc.)