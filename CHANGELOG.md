# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]


## [v0.4.1]

### Added

- Scoop publisher now includes a Windows arm64 artifact when present — generates `url_arm64` / `sha256_arm64` fields in the manifest; arm64 is optional and omitted when no `windows-aarch64` zip is found in `dist/`
- `findWindowsZipByArch` helper replaces the old `findWindowsZip` — detects artifacts by explicit architecture token (`x86_64`, `aarch64`) instead of heuristic preference (#14)
- Windows aarch64 added as a cross-compilation target in `takeoff.jsonc`
- Integration tests for `publishScoopManifest` in dry-run mode (both-arch and x64-only scenarios)
- `--all-publishers` / `--all` flag for `takeoff release` — enables all configured secondary publishers (aur, homebrew, scoop, winget, chocolatey) in a single invocation
- `--no-github` flag for `takeoff release` — skips creating/updating the GitHub Release and uploading assets; looks up the existing release URL and runs only the secondary publishers. Useful for re-running a publisher (e.g. `--no-github --scoop`) when the GitHub Release already exists without re-uploading assets.
- `ReleaseContext` abstraction (`src/release/context.zig`) — centralises release asset URL resolution for all secondary publishers; supports both a GitHub source (owner/repo/tag) and an explicit asset manifest, with `assetUrl()` and `repoGitUrl()` accessors
- `src/metadata.zig` — metadata resolver with explicit precedence rules (package-level → `project` block → internal defaults) for description, maintainer, homepage, and license
- `project.maintainer` and `project.url` optional fields in `takeoff.jsonc` — used as fallbacks when a package or publisher does not specify its own values
- `release.source` and `release.manifest` fields in `takeoff.jsonc` — groundwork for non-GitHub asset sources; `source = "manifest"` will allow secondary publishers to consume a pre-built asset map instead of uploading to GitHub

### Changed

- All secondary publishers (AUR, Homebrew, Scoop, Winget) now receive a `*const ReleaseContext` instead of raw `owner`/`repo`/`tag` strings; asset download URLs are resolved through `ctx.assetUrl()` rather than assembled inline
- Phase 2 of `takeoff release` (secondary publishers) now builds a `ReleaseContext` from the URL returned by Phase 1 and passes it to every publisher, making the release page URL the single source of truth
- Dry-run preview of secondary publishers also uses a `ReleaseContext` so the output mirrors what the real run would produce
- Publisher error sets (`AurError`, `HomebrewPublishError`, `ScoopPublishError`, `WingetPublishError`) extended with `AssetNotFound` and `InvalidManifest` to surface `ReleaseContext.assetUrl()` failures cleanly

### Fixed

- Scoop manifest was written to `dist/bucket/` during `takeoff build` but to `dist/scoop/` during `takeoff release` — both phases now consistently use `dist/scoop/`
- Winget test no longer creates a stale `winget-out/` directory in the project root; output is written inside the test's `tmpDir` and cleaned up automatically

## [v0.4.0] - 2026-04-03

### Added

- `takeoff release --replace-assets` flag — for each artifact being uploaded, deletes only the same-named existing asset before uploading; mutually exclusive with `--clean-assets` (#35)
- Native Scoop manifest generation — produces a valid `<name>.json` manifest with download URL, hash, and architecture metadata (#14)
- Native Winget manifest generation — produces a valid YAML manifest set (`version`, `installer`, `defaultLocale`) ready for submission to `winget-pkgs` (#15)
- AUR publisher now generates `LICENSE` (0BSD) and `REUSE.toml` files per RFC 40 / RFC 52
- Optional `maintainer` field in `release.aur` config for proper PKGBUILD header

### Fixed

- Homebrew formula template now includes an explicit `version` field, preventing `brew` from inferring a wrong version from the tarball filename (e.g., `64` from `aarch64`)
- Homebrew publisher logs a visible warning when no SSH key is found instead of silently skipping the tap push; accepts `HOMEBREW_TAP_SSH_KEY` environment variable as fallback
- Homebrew tap temp directory is now removed before cloning and cleaned up on both success and failure, preventing "already exists" errors on re-runs (#38)
- `takeoff release` now validates that artifact filenames in `dist/` contain the target tag before uploading, aborting early if there is a mismatch (#37)

### Changed

- SSH key for publishers can now be provided via a common `TAKEOFF_SSH_KEY` environment variable as a fallback when no publisher-specific key is configured (#36)
- AUR package name defaults to project name instead of requiring `-bin` suffix
- AUR publisher falls back to `~/.ssh/config` when no explicit SSH key is configured (same for Homebrew)
- AUR PKGBUILD uses explicit directory path instead of fragile `find` command
- AUR PKGBUILD removes redundant `provides`/`conflicts` for self (complies with Arch guidelines)
- AUR PKGBUILD installs upstream LICENSE to `/usr/share/licenses/<pkgname>/`

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
