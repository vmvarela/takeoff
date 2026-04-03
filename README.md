<p align="center">
  <img src="./logo.png" alt="takeoff logo" />
</p>

# takeoff

**Release automation for Zig projects. Cross-compile once, package everywhere.**

## Why I built this

I maintain a few open-source CLI tools. Every time I published a new release, I found myself doing the same manual steps: build for each target, rename the tarballs, upload them to GitHub Releases, update the AUR package... The fourth time I did it, I stopped and wrote this instead.

I am not a Zig expert. This project was built with the help of AI tools (mostly OpenCode + Claude), guided by my own experience with release workflows. I know what I want the tool to do; I am still learning the language it is written in. I mention this so you know what you are getting into if you use it or contribute.

The tool is currently used to release `takeoff` itself. `sql-pipe` is next.

**Status:** pre-alpha — core functionality works, but the API may change.

---

## What is this?

Zig can cross-compile to any target from a single machine — no Docker containers, no remote builders, no platform-specific CI configurations. `takeoff` automates this into a complete release pipeline: build all your binaries in parallel, package them for different package managers, and publish to GitHub Releases with a single command.

It does not try to compete with GoReleaser or cargo-dist. Those are excellent tools for their ecosystems. `takeoff` exists because those tools did not fit my needs: I wanted something simple, with no paid features, that worked with just Zig installed.

---

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

---

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

`takeoff` looks for config in this order:

1. `takeoff.json`
2. `takeoff.jsonc` (with comments)
3. `.takeoff.json`
4. `.takeoff.jsonc`
5. `.config/takeoff.json`
6. `.config/takeoff.jsonc`

---

## Commands

### `takeoff check`

Validates your configuration and environment before you do anything else:

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

Compiles your project for all configured targets in parallel:

```bash
takeoff build          # Build with defaults
takeoff build -j 8     # 8 parallel jobs
takeoff build -O ReleaseSmall   # Smaller binaries
takeoff build --dry-run         # Preview without building
```

### `takeoff release`

Publishes artifacts to GitHub Releases:

```bash
GITHUB_TOKEN=xxx takeoff release          # Release current git tag
takeoff release --tag v1.0.0              # Release specific tag
takeoff release --draft                   # Create a draft release
takeoff release --clean-assets            # Replace existing assets
takeoff release --aur                     # Also publish AUR metadata
```

Requires `GITHUB_TOKEN` with `repo` scope.
For AUR publishing, configure `release.aur.repo` and optionally `release.aur.aur_ssh_key` (or set `AUR_SSH_KEY` env var).

### `takeoff verify`

Verifies checksums against a checksums file:

```bash
takeoff verify                                  # Auto-detect file and algorithm
takeoff verify -f checksums-sha256.txt -a sha256
```

### `takeoff bump`

Bumps the version in `build.zig.zon` and checks that `CHANGELOG.md` has a matching entry:

```bash
takeoff bump            # Bump patch (default)
takeoff bump --minor
takeoff bump --major
takeoff bump --version 1.0.0
takeoff bump --dry-run  # Preview without writing
```

`takeoff check` will warn if `build.zig.zon` and `CHANGELOG.md` are out of sync.

---

## How it works

`takeoff` is built on Zig's native cross-compilation and the stdlib's HTTP client. No libcurl, no external dependencies.

Build process:
1. Parse `takeoff.jsonc` and validate against your installed Zig version
2. Create a thread pool (default: CPU count)
3. Spawn `zig build` for each target with `-Dtarget=...`
4. Collect artifacts into `dist/`
5. Generate packages and checksums

Parallel builds use `std.Thread.Pool` — each target compiles in isolation, output is streamed to your terminal in order. GitHub integration uses `std.http.Client` directly.

---

## Comparison

| Tool | Cross-compilation | Packaging | GitHub Releases | Zero dependencies |
|------|:-----------------:|:---------:|:---------------:|:-----------------:|
| GoReleaser | Needs toolchains | ✓ | ✓ | ✗ |
| cargo-dist | Native | ✓ | ✓ | ✗ |
| **takeoff** | **Native** | **✓** | **✓** | **✓** |

Use `takeoff` when you are releasing a Zig project and want something that works on any machine with Zig installed, without Docker or paid features.

---

## Current limitations

- AUR flow targets Linux `x86_64` tarball artifacts only (`-bin` packages)
- AUR publish requires SSH access to `aur.archlinux.org`
- No code signing yet
- Configuration is JSONC only (no TOML/YAML)

---

## Requirements

- Zig 0.16.0 or later
- `GITHUB_TOKEN` for release publishing
- Optional: `appimagetool`, `wixl`, `dpkg-deb`, `rpmbuild`, `apk`, `makepkg`, `namcap`

---

## License

MIT — see [LICENSE](./LICENSE)
