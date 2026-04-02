# Changelog

All notable changes to this project will be documented in this file.

## [v0.2.0] - 2026-03-31

### Added

- Native Alpine `.apk` packager for Linux targets, wired into the packaging pipeline and checksum generation
- Native Arch Linux AUR publisher support with generated `PKGBUILD` and `.SRCINFO`
- `zr release --aur` to generate/update AUR metadata and optionally push to AUR via SSH
- `release.aur` configuration block in `zr.jsonc` with `repo` and optional `aur_ssh_key`

### Fixed

- APK payload compatibility with `apk-tools` by adding required per-file PAX checksum headers and correct data tar paths
- GitHub release client panic on network/TLS edge path by using the safer request connection flow

### Changed

- Release artifact discovery now includes `.deb`, `.rpm`, and `.apk` files
- `zr check` optional tools list now includes `namcap`

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
