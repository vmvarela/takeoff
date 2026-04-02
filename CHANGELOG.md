# Changelog

All notable changes to this project will be documented in this file.

## [v0.3.0] - 2026-04-02

### Added

- Native Homebrew formula generation — produces a valid Ruby `.rb` formula with tarball URL, sha256, and `head` install support
- Homebrew tap publisher — clones a shared tap repo, writes `Formula/<name>.rb`, commits and pushes via SSH
- `takeoff release --homebrew` flag to generate and publish a Homebrew formula alongside a GitHub release
- `packages.homebrew` configuration block in `takeoff.jsonc` with `tap`, `tap_ssh_key`, `description`, and `homepage` options
- `takeoff bump` command to synchronise version between `build.zig.zon` and `CHANGELOG.md` with `--major`, `--minor`, `--patch`, `--version`, and `--dry-run` options
- Version consistency check in `takeoff check` — warns when `build.zig.zon` and `CHANGELOG.md` have different versions

### Changed

- `takeoff check` optional tools section now clarifies that none are required and uses a neutral symbol for unavailable tools

### Fixed

- `takeoff release --clean-assets` now properly deletes old assets before uploading new ones
- Homebrew formula template passes `brew audit --strict` with no warnings

## [v0.2.0] - 2026-03-31

### Added

- Native Alpine `.apk` packager for Linux targets, wired into the packaging pipeline and checksum generation
- Native Arch Linux AUR publisher support with generated `PKGBUILD` and `.SRCINFO`
- `takeoff release --aur` to generate/update AUR metadata and optionally push to AUR via SSH
- `release.aur` configuration block in `takeoff.jsonc` with `repo` and optional `aur_ssh_key`

### Fixed

- APK payload compatibility with `apk-tools` by adding required per-file PAX checksum headers and correct data tar paths
- GitHub release client panic on network/TLS edge path by using the safer request connection flow

### Changed

- Release artifact discovery now includes `.deb`, `.rpm`, and `.apk` files
- `takeoff check` optional tools list now includes `namcap`

## [v0.1.0] - 2026-03-29

### Added

- Cross-compile binaries for Linux x86_64, macOS aarch64/x86_64, and Windows x86_64 from a single runner
- Parallel builds via `std.Io.Group` — all targets built concurrently
- `takeoff build` — cross-compile all targets and produce `.tar.gz` / `.zip` archives with checksums
- `takeoff verify` — verify SHA-256 and BLAKE3 checksums against a checksums file
- `takeoff release` — publish a GitHub Release via API and upload artifacts
- `takeoff check` — pre-flight validation: config, zig version, GITHUB_TOKEN, dry-run builds per target, optional tools
- JSONC config (`takeoff.jsonc`) with full support for targets, packages, and GitHub release settings
- Zero runtime dependencies: no libc, no OpenSSL, no libcurl — pure Zig stdlib
