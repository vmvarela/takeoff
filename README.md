<p align="center">
  <img src="./logo.png" alt="takeoff logo" />
</p>

# takeoff
**Release automation for Zig projects. Cross-compile once, package everywhere.**

## What is this?

Zig can cross-compile to any target from a single machine — no Docker containers, no remote builders, no platform-specific CI configurations. `takeoff` automates this into a complete release pipeline: build all your binaries in parallel, package them for different package managers, and publish to GitHub Releases with a single command.

I built this after the third time I found myself manually uploading tarballs to GitHub Releases. The workflow should be: tag a commit, run `takeoff release`, done.

**Status:** pre-alpha — core functionality works but API may change

## Quick Start

```bash
# Install (requires Zig 0.16.0+)
zig build --release=safe

# Verify your setup
takeoff check

# Build for all configured targets
takeoff build

# Publish a release (requires GITHUB_TOKEN)
takeoff release
```

## Configuration

Create `takeoff.jsonc` in your project root:

```jsonc
{
    "project": {
        "name": "myapp",
        "description": "A Zig CLI tool",
        "license": "MIT"
    },
    "build": {
        "zig_version": "0.16.0"
    },
    "targets": [
        { "os": "linux", "arch": "x86_64" },
        { "os": "macos", "arch": "aarch64" },
        { "os": "macos", "arch": "x86_64" },
        { "os": "windows", "arch": "x86_64" }
    ],
    "packages": {
        "tarball": {
            "format": "tar.gz",
            "extra_files": ["LICENSE", "README.md"]
        }
    },
    "release": {
        "github": {
            "owner": "yourname",
            "repo": "myapp"
        },
        "aur": {
            "repo": "myapp-bin"
            // Optional, otherwise AUR_SSH_KEY env is used:
            // "aur_ssh_key": "/home/you/.ssh/aur"
        }
    }
}
```

### Configuration paths

`takeoff` looks for config in this order:
1. `takeoff.json`
2. `takeoff.jsonc` (with comments)
3. `.takeoff.json`
4. `.takeoff.jsonc`
5. `.config/takeoff.json`
6. `.config/takeoff.jsonc`

## Commands

### `takeoff check`

Validates your configuration and environment:

```
Pre-flight checks
================
✓ Config OK: takeoff.jsonc
✓ Version consistent: 0.2.0 (build.zig.zon == CHANGELOG.md)
✓ zig version OK: 0.16.0 (required >= 0.16.0)
✓ GITHUB_TOKEN OK: can access vmvarela/takeoff
✓ dry-run target OK: x86_64-linux

Optional tools
--------------
✓ appimagetool
! wixl (not installed)
✓ gpg
```

### `takeoff build`

Compiles your project for all targets in parallel:

```bash
# Build with defaults
takeoff build

# Build with 8 parallel jobs
takeoff build -j 8

# Build for smaller binaries
takeoff build -O ReleaseSmall

# See what would be built without building
takeoff build --dry-run
```

### `takeoff release`

Publishes artifacts to GitHub Releases:

```bash
# Release current git tag
GITHUB_TOKEN=xxx takeoff release

# Release specific tag
takeoff release --tag v1.0.0

# Create a draft release
takeoff release --draft

# Replace existing assets
takeoff release --clean-assets

# Also generate/publish AUR metadata (requires release.aur config)
takeoff release --aur
```

Requires `GITHUB_TOKEN` environment variable with `repo` scope.

For AUR publishing (`--aur`), configure `release.aur.repo` and optionally
`release.aur.aur_ssh_key` in `takeoff.jsonc` (or set `AUR_SSH_KEY` env var).

### `takeoff verify`

Verifies checksums against a checksums file:

```bash
# Auto-detect checksums file and algorithm
takeoff verify

# Verify specific file with SHA-256
takeoff verify -f checksums-sha256.txt -a sha256
```

### `takeoff bump`

Bumps the project version in `build.zig.zon` and verifies that `CHANGELOG.md` has a matching entry:

```bash
# Bump patch version (default)
takeoff bump

# Bump minor or major
takeoff bump --minor
takeoff bump --major

# Set explicit version
takeoff bump --version 1.0.0

# Preview without writing files
takeoff bump --dry-run
```

This keeps the two version sources in sync. The release process reads the version from `git describe --tags`, but `build.zig.zon` is what `zig build` uses for `TakeOff.VERSION`. Run `bump` before tagging a release.

`takeoff check` will warn if `build.zig.zon` and `CHANGELOG.md` have different versions.

## Under the Hood

`takeoff` is built on Zig's native cross-compilation and the stdlib's HTTP client. No libcurl, no external dependencies.

**Build process:**
1. Parse `takeoff.jsonc` and validate against your installed Zig version
2. Create a thread pool (default: CPU count)
3. Spawn `zig build` for each target with `-Dtarget=...`
4. Collect artifacts into `dist/` directory
5. Generate packages and checksums

**Parallel builds** use `std.Thread.Pool` — each target compiles in isolation, but output is streamed to your terminal in order.

**GitHub integration** uses `std.http.Client` directly. The only external requirement is the `GITHUB_TOKEN` environment variable.

## Why `takeoff` over alternatives?

| Tool | Cross-compilation | Packaging | GitHub Releases | Zero dependencies |
|------|-------------------|-----------|-----------------|-------------------|
| GoReleaser | Needs toolchains | Yes | Yes | No (Go + libs) |
| cargo-dist | Native | Yes | Yes | No (Rust toolchain) |
| **takeoff** | **Native** | **Yes** | **Yes** | **Yes** |

GoReleaser and cargo-dist are excellent tools for their ecosystems. Use `takeoff` when:
- You're releasing a Zig project
- You want builds to work on any machine with just Zig installed
- You need packaging without running Docker containers

## Limitations

- AUR flow currently targets Linux `x86_64` tarball artifacts (`-bin` packages)
- AUR publish requires SSH access to `aur.archlinux.org`
- No code signing yet
- Configuration is JSON/JSONC only (no TOML/YAML)

## Requirements

- Zig 0.16.0 or later
- `GITHUB_TOKEN` for release publishing
- Optional: `appimagetool`, `wixl`, `dpkg-deb`, `rpmbuild`, `apk`, `makepkg`, `namcap`

## License

MIT — see [LICENSE](./LICENSE)
