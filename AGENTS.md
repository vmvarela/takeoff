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
| Free optional string | `if (opt) \|v\| allocator.free(v);` | `allocator.free(opt)` (type error) |
| Discard a value | `_ = value;` | `value;` (compile error) |
| Current working directory | `std.Io.Dir.cwd()` | `std.fs.cwd()` |
| Open a file for reading | `std.Io.Dir.cwd().openFile(io, path, .{})` | `std.fs.cwd().openFile(path, .{})` |
| Read entire file | `std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max))` | `std.fs.cwd().readFileAlloc(allocator, path, max)` |
| Create a file | `std.Io.Dir.cwd().createFile(io, path)` | `std.fs.cwd().createFile(path, .{})` |
| Write to file | `file.writeStreamingAll(io, data)` | `file.writeAll(data)` (doesn't exist on `std.Io.File`) |
| Close a file | `file.close(io)` | `file.close()` (no args) |
| Create a file | `std.Io.Dir.cwd().createFile(io, path, .{...})` | `std.Io.Dir.cwd().createFile(io, path)` (3rd arg required) |
| Iterate directory | `var iter = dir.iterate(); while (iter.next(io) catch null) |entry| { ... }` | `dir.iterate(io)` or `iter.next()` |
| SHA-256 hasher | `std.crypto.hash.sha2.Sha256.init(.{})` | `std.crypto.hash.Sha2.init(.{})` |
| SHA-256 digest length | `std.crypto.hash.sha2.Sha256.digest_length` | `std.crypto.hash.Sha2.digest_length` |
| ArrayList writer | `list.writer(allocator)` returns `*std.Io.Writer` | `list.writer()` (no allocator) |
| GPA allocator | `std.heap.page_allocator` (GPA removed) | `std.heap.GeneralPurposeAllocator(.{}){}` |
| JSON stringify to string | `std.json.Stringify.valueAlloc(allocator, value, .{...})` | `std.json.stringifyAlloc(...)` (removed) |
| JSON streaming writer | `var jw = std.json.Stringify{ .writer = w, .options = .{...} }; try jw.beginObject(); ...` | `std.json.writeStream(...)` (doesn't exist) |
| JSON serialize with writer | `var jw = std.json.Stringify{ .writer = w, .options = .{...} }; try jw.beginObject(); ...` | `std.json.stringify(value, .{...}, writer)` |
| Child process spawn | `var child = std.process.Child.init(argv, allocator); child.spawn(); ...; child.wait(io);` | `std.process.Child.init(...)` then `child.wait()` (io arg needed) |
| Child process result | `std.process.Child.Term` | `std.process.Child.RunResult` (doesn't exist) |
| Child process result | `std.process.Child.Term` | `std.process.Term` (doesn't exist at top level) |
| Run process with cwd | Use `sh -c "git -C \"{dir}\" ..."` via `std.process.run` | `std.process.Child.init` + `child.cwd = ...` (Child.init doesn't exist in 0.16) |
| `std.fs.path.dirname` | Returns `?[]const u8` (no error union) | `try std.fs.path.dirname(...)` |

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
- **`std.fs` is mostly gone for file I/O.** Use `std.Io.Dir.cwd()` for the
  current directory, then call `.openFile(io, path, .{})`, `.createFile(io, path)`,
  `.createDirPath(io, path)`, `.readFileAlloc(io, path, allocator, .limited(max))`.
  `std.fs.path` still works for path manipulation (dirname, basename, join).
- **`std.json.stringifyAlloc` was removed.** Use `std.json.Stringify.valueAlloc(allocator, value, .{...})`
  to get a JSON string, or construct a `std.json.Stringify` manually with
  `.writer` and `.options` fields and call `.beginObject()`, `.objectField()`,
  `.write()`, `.endObject()` etc.
- **Optional struct fields serialize as `null` in JSON.** If you need to omit
  a field entirely (e.g. Scoop manifest without arm64), use manual
  `std.fmt.allocPrint` with conditional blocks or the `std.json.Stringify`
  streaming API — don't rely on struct-based serialization.
- **Memory leaks in conditional allocPrint blocks.** When using `if (opt) |x| blk: { ... break :blk try std.fmt.allocPrint(...) } else ""`,
  the allocated string is returned but never freed. Use an `ArenaAllocator`
  for intermediate allocations: `var arena = std.heap.ArenaAllocator.init(allocator); defer arena.deinit(); const a = arena.allocator();`
- **`std.fs.cwd()` does not exist.** Use `std.Io.Dir.cwd()` instead.
- **`std.crypto.hash.Sha2` does not exist.** Use `std.crypto.hash.sha2.Sha256`
  (note the lowercase `sha2` namespace and explicit `Sha256`).
- **`std.heap.GeneralPurposeAllocator` was removed.** Use `std.heap.page_allocator`
  or `std.heap.ArenaAllocator` instead.
- **`ArrayList` has no `writer()` method in 0.16.** Use `std.fmt.allocPrint` +
  `appendSlice`, or `std.io.fixedBufferStream` with a writer.
- **`file.readAll()` doesn't exist on `std.Io.File`.** Use `file.readAll(&buf)`
  which is a method on the file handle.
- **`file.writeAll()` doesn't exist on `std.Io.File`.** Use
  `file.writeStreamingAll(io, data)` instead.
- **`file.close()` takes an `io` argument in 0.16.** Use `file.close(io)`.
- **`std.Io.Dir.cwd().createFile()` takes 3 args:** `io`, `path`, and `.options`
  (e.g. `.createFile(io, path, .{})`). Missing the third arg is a compile error.
- **`dir.iterate()` takes no args; `iter.next(io)` takes `io`.** Pattern:
  `var iter = dir.iterate(); while (iter.next(io) catch null) |entry| { ... }`
- **`std.fs.path.dirname` returns `?[]const u8`, not an error union.** Do NOT
  use `try` — it's a plain optional.
- **`std.process.Child.init` does not exist in 0.16.** To run a command with a
  specific working directory, use `sh -c "git -C \"{dir}\" ..."` via
  `std.process.run`. The old `Child.init` + `child.cwd = ...` pattern is gone.
- **`std.process.Child.RunResult` and `std.process.Term` do not exist.** Use
  `std.process.Child.Term` for the exit status union.
- **`child.wait()` requires an `io` argument in 0.16.** Use `child.wait(io)`.
- **`std.process.run` does not support setting cwd.** If you need to run a
  command in a specific directory, use `sh -c "cd dir && ..."` or the
  `git -C "dir" ...` pattern for git commands.
- **`std.process.run` needs an allocator that supports `allocSentinel`.**
  `std.heap.page_allocator` does NOT work — `spawnPosix` internally calls
  `allocSentinel` which requires alignment support. Use an `ArenaAllocator`
  or any allocator that supports aligned allocations. The main binary works
  fine because `main()` uses an arena; standalone test binaries using
  `page_allocator` will fail with `OutOfMemory` during process spawning.
- **`std.Io.Dir` has no `realpath` method — use `realPath` (capital P).**
  `realPath(dir, io, out_buffer)` returns `usize` (length written); slice
  with `buf[0..n]` to get the path string. To resolve a sub-path within a
  dir use `realPathFile(dir, io, sub_path, out_buffer) !usize`. Allocating
  variants: `realPathFileAlloc(dir, io, sub_path, allocator) ![:0]u8`.
  Pattern in tests:
  ```zig
  var buf: [std.fs.max_path_bytes]u8 = undefined;
  const n = try tmp.dir.realPath(io, &buf);
  const tmp_path = buf[0..n];
  ```

## Release workflow (dogfooding)

When releasing a new version of takeoff itself:

1. `takeoff bump --minor` — bumps version and updates CHANGELOG.md
2. `git tag vX.Y.Z && git push origin vX.Y.Z` — create and push the tag
3. `takeoff build` — rebuild artifacts so filenames include the new tag

### Known issue: Homebrew temp dir not cleaned on failure

If the Homebrew tap push fails mid-way, the directory
`/tmp/takeoff-homebrew-<tap>-<version>` is left behind and the next run fails
with "already exists". Fix: `rm -rf /tmp/takeoff-homebrew-*` before retrying.
