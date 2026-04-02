# AGENTS.md — AI Coding Assistant Guide for takeoff

## Project overview

`takeoff` is a release automation tool for Zig projects. It cross-compiles binaries for all targets on a single Linux runner, then packages them into native formats for each OS/distribution.

## Repository structure

- `src/` — all Zig source code
- `src/packagers/` — one file per package format (.deb, .rpm, etc.)
- `src/publishers/` — GitHub, AUR, Homebrew tap publishers
- `build.zig` — the project build file
- `takeoff.jsonc` — takeoff's own release config (dogfooding)

## Key constraints

- Minimum Zig version: 0.16.0
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

## Zig 0.16 API notes

This project targets Zig 0.16.0-dev. Several stdlib APIs changed from earlier
versions. Use the patterns below — do not use the old equivalents.

| What you want | Zig 0.16 API | Old / wrong |
|---|---|---|
| Empty ArrayList | `var list: std.ArrayList(T) = .empty;` | `.init(allocator)` |
| Append slice to ArrayList | `list.appendSlice(allocator, items)` | `list.appendSlice(items)` |
| Trim leading whitespace | `std.mem.trim(u8, s, " \t")` | `std.mem.trimLeft` (removed) |
| Trim trailing whitespace | `std.mem.trim(u8, s, " \t")` | `std.mem.trimRight` (removed) |
| Format into ArrayList | Use `appendSlice` + `std.fmt.allocPrint` | `std.fmt.format(list.writer(allocator), ...)` |
| Free optional string | `if (opt) |v| allocator.free(v);` | `allocator.free(opt)` (type error) |
| Discard a value | `_ = value;` | `value;` (compile error) |

### Common gotchas

- **`std.ArrayList` is unmanaged by default** in 0.16. Use `.empty` to
  initialise and always pass the allocator to mutating methods.
- **`std.mem.trimLeft` / `std.mem.trimRight` were removed.** Use
  `std.mem.trim(u8, slice, cutset)` — it trims both sides. If you need
  one-sided trimming, slice the result yourself.
- **`std.fmt.format(writer, ...)` no longer works on `ArrayList.writer()`.**
  Build the string with `std.fmt.allocPrint` then `appendSlice`, or use
  `std.io.fixedBufferStream` with a writer.
- **`defer allocator.free(optional)` fails** when the optional is `null`
  because `@TypeOf(null)` is not a slice. Always unwrap first:
  `defer if (opt) |v| allocator.free(v);`.
- **Unused values are compile errors.** If you have a local constant you
  deliberately don't use, discard it with `_ = name;`.
- **`log.err` in CLI validation causes `zig build test` to fail** even when all
  tests pass, because the test runner counts every `log.err` call as a failure.
  Use `log.warn` for user-facing argument errors (invalid flag, missing value,
  mutually exclusive flags, etc.). Reserve `log.err` for genuine internal
  failures (network errors, I/O failures, unexpected state).

## Release workflow (dogfooding)

When releasing a new version of takeoff itself:

1. `takeoff bump --minor` — bumps version and updates CHANGELOG.md
2. `git tag vX.Y.Z && git push origin vX.Y.Z` — create and push the tag
3. `takeoff build` — rebuild artifacts so filenames include the new tag
4. `HOMEBREW_TAP_SSH_KEY=~/.ssh/id_rsa_vmvarela takeoff release --tag vX.Y.Z --replace-assets --homebrew`
   - Always pass `--tag` explicitly. Without it, `takeoff release` calls
     `git describe --tags`, which returns `vX.Y.Z-N-gSHA` if there are commits
     after the tag — creating a spurious release with the wrong name.
   - `--replace-assets` handles re-releases cleanly without a full wipe.
   - `HOMEBREW_TAP_SSH_KEY` must point to the key for the `vmvarela` GitHub
     account (`~/.ssh/id_rsa_vmvarela`). The default `github.com` SSH host in
     this machine maps to a different account (`id_rsa_prisa`).

### Known issue: Homebrew temp dir not cleaned on failure

If the Homebrew tap push fails mid-way, the directory
`/tmp/takeoff-homebrew-<tap>-<version>` is left behind and the next run fails
with "already exists". Fix: `rm -rf /tmp/takeoff-homebrew-*` before retrying.
