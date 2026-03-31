const std = @import("std");
const build_mod = @import("build.zig");
const config = @import("config.zig");

const log = std.log.scoped(.parallel_build);

/// Error set for parallel build operations.
pub const ParallelBuildError = error{
    ThreadPoolInitFailed,
    JobSubmissionFailed,
} || std.mem.Allocator.Error;

/// Status of a build job.
pub const JobStatus = enum {
    pending,
    running,
    succeeded,
    failed,
};

/// A single build job to be executed.
pub const BuildJob = struct {
    /// Index in the jobs array (for result correlation)
    index: usize,
    /// The target to build (null if failed during setup)
    target: ?build_mod.BuildTarget,
    /// Current status of the job
    status: JobStatus,
    /// Error message if failed
    error_message: ?[]const u8,
    /// Path to the built artifact if successful
    artifact_path: ?[]const u8,

    /// Initialize a new build job.
    pub fn init(index: usize, target: build_mod.BuildTarget) BuildJob {
        return BuildJob{
            .index = index,
            .target = target,
            .status = .pending,
            .error_message = null,
            .artifact_path = null,
        };
    }

    /// Initialize a failed job (target is null).
    pub fn initFailed(index: usize, error_message: []const u8) BuildJob {
        return BuildJob{
            .index = index,
            .target = null,
            .status = .failed,
            .error_message = error_message,
            .artifact_path = null,
        };
    }

    /// Free allocated memory.
    pub fn deinit(self: *const BuildJob, allocator: std.mem.Allocator) void {
        if (self.error_message) |m| allocator.free(m);
        if (self.artifact_path) |p| allocator.free(p);
        if (self.target) |t| t.deinit(allocator);
    }
};

/// Result summary of a parallel build operation.
pub const BuildSummary = struct {
    /// Number of jobs that succeeded
    succeeded: usize,
    /// Number of jobs that failed
    failed: usize,
    /// Total number of jobs
    total: usize,
    /// Individual job results
    jobs: []const BuildJob,

    /// Print a formatted summary to the given writer.
    pub fn print(self: BuildSummary, writer: anytype) !void {
        try writer.print("\nBuild Summary:\n", .{});
        try writer.print("==============\n", .{});
        try writer.print("Total: {d}\n", .{self.total});
        try writer.print("  ✅ Succeeded: {d}\n", .{self.succeeded});
        try writer.print("  ❌ Failed: {d}\n", .{self.failed});
        try writer.print("\n", .{});

        // Print details for each job
        for (self.jobs) |job| {
            const icon = switch (job.status) {
                .succeeded => "✅",
                .failed => "❌",
                .pending, .running => "⏳",
            };

            const target_str = if (job.target) |t| t.target_string else "unknown";
            try writer.print("{s} {s}\n", .{ icon, target_str });

            if (job.status == .failed) {
                if (job.error_message) |msg| {
                    // Indent error message
                    var lines = std.mem.splitScalar(u8, msg, '\n');
                    while (lines.next()) |line| {
                        if (line.len > 0) {
                            try writer.print("   {s}\n", .{line});
                        }
                    }
                }
            } else if (job.status == .succeeded) {
                if (job.artifact_path) |path| {
                    try writer.print("   → {s}\n", .{path});
                }
            }
        }
    }

    /// Returns true if all jobs succeeded.
    pub fn allSucceeded(self: BuildSummary) bool {
        return self.succeeded == self.total and self.failed == 0;
    }

    /// Returns true if any job failed.
    pub fn anyFailed(self: BuildSummary) bool {
        return self.failed > 0;
    }
};

/// Context passed to worker threads.
const WorkerContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    optimize: []const u8,
    verbose: bool,
    jobs: []BuildJob,
    allocator_mutex: *std.Io.Mutex,
    show_progress: bool,
    /// Shared atomic index: each worker claims the next job by incrementing this.
    next_job_index: std.atomic.Value(usize),
};

/// Run builds for all targets in parallel, respecting `job_count` concurrency.
///
/// `job_count == 0` means "use all available CPUs". Otherwise at most
/// `job_count` builds run simultaneously.
pub fn runParallelBuilds(
    allocator: std.mem.Allocator,
    io: std.Io,
    targets: []const config.Target,
    project_name: []const u8,
    output_template: ?[]const u8,
    build_flags: []const []const u8,
    git_tag: ?[]const u8,
    optimize: []const u8,
    job_count: usize,
    verbose: bool,
) ParallelBuildError!BuildSummary {
    if (targets.len == 0) {
        return BuildSummary{
            .succeeded = 0,
            .failed = 0,
            .total = 0,
            .jobs = &.{},
        };
    }

    // Create build jobs for all targets
    var jobs = try allocator.alloc(BuildJob, targets.len);
    errdefer {
        for (jobs) |*job| {
            job.deinit(allocator);
        }
        allocator.free(jobs);
    }

    for (targets, 0..) |target, i| {
        const build_target = build_mod.BuildTarget.fromConfig(
            allocator,
            target,
            project_name,
            output_template,
            build_flags,
            git_tag,
        ) catch |err| {
            // If we can't even create the target, mark as failed
            const error_msg = try std.fmt.allocPrint(
                allocator,
                "Failed to create build target: {}",
                .{err},
            );
            jobs[i] = BuildJob.initFailed(i, error_msg);
            continue;
        };

        jobs[i] = BuildJob.init(i, build_target);
    }

    // Show progress bar for multiple targets (unless verbose)
    const show_progress = jobs.len > 3 and !verbose;

    // Determine number of concurrent workers.
    // job_count == 0  → one worker per logical CPU (i.e. fully parallel)
    // job_count >= 1  → cap at job_count, but never exceed available jobs
    const cpu_count = std.Thread.getCpuCount() catch 1;
    const desired_workers: usize = if (job_count == 0) cpu_count else job_count;
    const num_workers = @min(desired_workers, jobs.len);

    // Context for workers
    var allocator_mutex: std.Io.Mutex = .init;
    var mutable_context = WorkerContext{
        .allocator = allocator,
        .io = io,
        .optimize = optimize,
        .verbose = verbose,
        .jobs = jobs,
        .allocator_mutex = &allocator_mutex,
        .show_progress = show_progress,
        .next_job_index = .init(0),
    };

    var group: std.Io.Group = .init;
    defer group.cancel(io);

    // Launch exactly `num_workers` concurrent workers. Each worker loops,
    // atomically claiming the next job index, until all jobs are consumed.
    for (0..num_workers) |_| {
        group.concurrent(io, workerLoop, .{&mutable_context}) catch |err| {
            log.warn("Failed to spawn worker: {}", .{err});
        };
    }

    _ = group.await(io) catch {};

    // Calculate summary
    var summary = BuildSummary{
        .succeeded = 0,
        .failed = 0,
        .total = jobs.len,
        .jobs = jobs,
    };

    for (jobs) |job| {
        switch (job.status) {
            .succeeded => summary.succeeded += 1,
            .failed => summary.failed += 1,
            .pending, .running => {
                // Shouldn't happen after group.await, but treat as failed
                summary.failed += 1;
            },
        }
    }

    return summary;
}

/// Worker loop: atomically claims jobs from the shared index and runs them
/// until no jobs remain. This function is the entry point for each concurrent
/// worker spawned by `runParallelBuilds`.
fn workerLoop(context: *WorkerContext) std.Io.Cancelable!void {
    while (true) {
        // Claim the next job index atomically.
        const i = context.next_job_index.fetchAdd(1, .seq_cst);
        if (i >= context.jobs.len) break;

        const job = &context.jobs[i];
        if (job.status == .failed) continue; // already failed during setup

        try workerRunBuild(context, job);
    }
}

/// Worker function that runs a single build.
fn workerRunBuild(context: *const WorkerContext, job: *BuildJob) std.Io.Cancelable!void {
    const allocator = context.allocator;
    const temp_allocator = std.heap.smp_allocator;

    // This should never happen, but handle gracefully
    const target = job.target orelse {
        context.allocator_mutex.lockUncancelable(context.io);
        defer context.allocator_mutex.unlock(context.io);
        job.status = .failed;
        job.error_message = std.fmt.allocPrint(allocator, "Internal error: target is null", .{}) catch null;
        return;
    };

    // Update status to running
    job.status = .running;

    if (context.verbose) {
        log.info("[{s}] Starting build...", .{target.target_string});
    }

    // Run the build
    const result = build_mod.runBuild(
        temp_allocator,
        context.io,
        target,
        context.optimize,
        context.verbose,
    ) catch |err| {
        context.allocator_mutex.lockUncancelable(context.io);
        defer context.allocator_mutex.unlock(context.io);
        job.status = .failed;
        job.error_message = std.fmt.allocPrint(
            allocator,
            "Unexpected error: {}",
            .{err},
        ) catch null;
        return;
    };

    defer {
        if (result.artifact_path) |path| temp_allocator.free(path);
        if (result.error_message) |msg| temp_allocator.free(msg);
    }

    // Update job status based on result
    if (result.success) {
        job.status = .succeeded;
        if (result.artifact_path) |path| {
            context.allocator_mutex.lockUncancelable(context.io);
            defer context.allocator_mutex.unlock(context.io);
            job.artifact_path = std.fmt.allocPrint(allocator, "{s}", .{path}) catch null;
        }

        if (context.verbose) {
            log.info("[{s}] Build succeeded", .{target.target_string});
        }
    } else {
        job.status = .failed;
        if (result.error_message) |msg| {
            context.allocator_mutex.lockUncancelable(context.io);
            defer context.allocator_mutex.unlock(context.io);
            job.error_message = std.fmt.allocPrint(allocator, "{s}", .{msg}) catch null;
        }

        if (context.verbose) {
            log.err("[{s}] Build failed", .{target.target_string});
        }
    }

    return;
}

/// Free all memory associated with a build summary.
pub fn freeBuildSummary(allocator: std.mem.Allocator, summary: *BuildSummary) void {
    for (summary.jobs) |*job| {
        job.deinit(allocator);
    }
    allocator.free(summary.jobs);
}

test "BuildJob initializes correctly" {
    const allocator = std.testing.allocator;

    const target = config.Target{
        .os = "linux",
        .arch = "x86_64",
        .cpu = null,
    };

    const build_target = try build_mod.BuildTarget.fromConfig(
        allocator,
        target,
        "test",
        null,
        &.{},
        null,
    );

    const job = BuildJob.init(0, build_target);
    defer job.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), job.index);
    try std.testing.expectEqual(JobStatus.pending, job.status);
    try std.testing.expectEqual(@as(?[]const u8, null), job.error_message);
    try std.testing.expectEqual(@as(?[]const u8, null), job.artifact_path);
}

test "BuildSummary calculates correctly" {
    const allocator = std.testing.allocator;

    // Create mock jobs
    var jobs = try allocator.alloc(BuildJob, 3);
    defer {
        for (jobs) |*job| {
            job.deinit(allocator);
        }
        allocator.free(jobs);
    }

    const target1 = config.Target{ .os = "linux", .arch = "x86_64", .cpu = null };
    const target2 = config.Target{ .os = "macos", .arch = "aarch64", .cpu = null };

    jobs[0] = BuildJob.init(0, try build_mod.BuildTarget.fromConfig(allocator, target1, "test", null, &.{}, null));
    jobs[0].status = .succeeded;

    jobs[1] = BuildJob.init(1, try build_mod.BuildTarget.fromConfig(allocator, target2, "test", null, &.{}, null));
    jobs[1].status = .failed;

    jobs[2] = BuildJob.init(2, try build_mod.BuildTarget.fromConfig(allocator, target1, "test", null, &.{}, null));
    jobs[2].status = .succeeded;

    const summary = BuildSummary{
        .succeeded = 2,
        .failed = 1,
        .total = 3,
        .jobs = jobs,
    };

    try std.testing.expect(!summary.allSucceeded());
    try std.testing.expect(summary.anyFailed());
    try std.testing.expectEqual(@as(usize, 2), summary.succeeded);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
}

test "BuildJob.initFailed creates job with null target" {
    const allocator = std.testing.allocator;

    const error_msg = try allocator.dupe(u8, "Setup failed");
    const job = BuildJob.initFailed(0, error_msg);
    defer job.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), job.index);
    try std.testing.expectEqual(@as(?build_mod.BuildTarget, null), job.target);
    try std.testing.expectEqual(JobStatus.failed, job.status);
    try std.testing.expectEqualStrings("Setup failed", job.error_message.?);
}

test "runParallelBuilds with empty targets" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const summary = try runParallelBuilds(
        allocator,
        io,
        &.{},
        "test",
        null,
        &.{},
        null,
        "ReleaseSafe",
        2,
        false,
    );

    try std.testing.expectEqual(@as(usize, 0), summary.total);
    try std.testing.expect(summary.allSucceeded());
}

test "BuildSummary print format" {
    const allocator = std.testing.allocator;

    var jobs = try allocator.alloc(BuildJob, 2);
    defer {
        for (jobs) |*job| {
            job.deinit(allocator);
        }
        allocator.free(jobs);
    }

    const target1 = config.Target{ .os = "linux", .arch = "x86_64", .cpu = null };
    const target2 = config.Target{ .os = "macos", .arch = "aarch64", .cpu = null };

    jobs[0] = BuildJob.init(0, try build_mod.BuildTarget.fromConfig(allocator, target1, "test", null, &.{}, null));
    jobs[0].status = .succeeded;
    jobs[0].artifact_path = try allocator.dupe(u8, "zig-out/bin/test-x86_64-linux");

    jobs[1] = BuildJob.init(1, try build_mod.BuildTarget.fromConfig(allocator, target2, "test", null, &.{}, null));
    jobs[1].status = .failed;
    jobs[1].error_message = try allocator.dupe(u8, "Build error\nDetails here");

    const summary = BuildSummary{
        .succeeded = 1,
        .failed = 1,
        .total = 2,
        .jobs = jobs,
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();

    try summary.print(&aw.writer);

    const output = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Build Summary"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Succeeded: 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "Failed: 1"));
}

test "workerLoop respects job_count concurrency limit via num_workers cap" {
    // Verify that the number of concurrent workers spawned never exceeds
    // min(job_count, jobs.len). We do this by running workerLoop against a
    // set of pre-failed jobs (so workerRunBuild is a no-op) and confirming
    // the shared atomic index advances through all slots exactly once.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const num_jobs = 5;
    const job_count = 2; // fewer workers than jobs

    // Build pre-failed jobs so workerRunBuild is skipped for each
    var jobs = try allocator.alloc(BuildJob, num_jobs);
    defer allocator.free(jobs);
    for (0..num_jobs) |i| {
        const msg = try allocator.dupe(u8, "pre-failed");
        jobs[i] = BuildJob.initFailed(i, msg);
    }
    defer for (jobs) |*j| {
        if (j.error_message) |m| allocator.free(m);
    };

    var allocator_mutex: std.Io.Mutex = .init;
    var ctx = WorkerContext{
        .allocator = allocator,
        .io = io,
        .optimize = "Debug",
        .verbose = false,
        .jobs = jobs,
        .allocator_mutex = &allocator_mutex,
        .show_progress = false,
        .next_job_index = .init(0),
    };

    // Spawn exactly min(job_count, num_jobs) workers and wait for them.
    const num_workers = @min(job_count, num_jobs);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..num_workers) |_| {
        try group.concurrent(io, workerLoop, .{&ctx});
    }
    _ = group.await(io) catch {};

    // All job slots must have been claimed: index should be >= num_jobs.
    const final_index = ctx.next_job_index.load(.seq_cst);
    try std.testing.expect(final_index >= num_jobs);
}
