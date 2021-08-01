const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const zigwin32_index_file = try (GitRepo{
        .url = "https://github.com/marlersoft/zigwin32",
        .sha = "2cde15a78def045bfae704ea39887c525bacac17",
    }).resolveOneFile(b.allocator, "win32.zig");

    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("audio-monitor", "src/main.zig");

    const assets_dir = "assets/";
    b.installDirectory(.{
        .source_dir = assets_dir,
        .install_subdir = assets_dir,
        .install_dir = std.build.InstallDir.bin,
    });

    if (mode != .Debug) exe.subsystem = .Windows;

    exe.linkLibC();
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    exe.addPackagePath("win32", zigwin32_index_file);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

// copied from https://github.com/marler8997/audio/blob/7cbc348bf45784c5583177f33682b55904d915cb/zig/build.zig
pub const GitRepo = struct {
    url: []const u8,
    sha: []const u8,
    branch: ?[]const u8 = null,
    path: ?[]const u8 = null,

    pub fn defaultReposDir(allocator: *std.mem.Allocator) ![]const u8 {
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        return try std.fs.path.join(allocator, &[_][]const u8{ cwd, "deps" });
    }

    pub fn resolve(self: GitRepo, allocator: *std.mem.Allocator) ![]const u8 {
        var optional_repos_dir_to_clean: ?[]const u8 = null;
        defer {
            if (optional_repos_dir_to_clean) |p| {
                allocator.free(p);
            }
        }

        const path = if (self.path) |p| try allocator.dupe(u8, p) else blk: {
            const repos_dir = try defaultReposDir(allocator);
            optional_repos_dir_to_clean = repos_dir;
            break :blk try std.fs.path.join(allocator, &[_][]const u8{ repos_dir, std.fs.path.basename(self.url) });
        };
        errdefer allocator.free(path);

        std.fs.accessAbsolute(path, std.fs.File.OpenFlags{ .read = true }) catch {
            std.debug.print("Error: repository '{s}' does not exist\n", .{path});
            std.debug.print("       Run the following to clone it:\n", .{});
            const branch_args = if (self.branch) |b| &[2][]const u8{ " -b ", b } else &[2][]const u8{ "", "" };
            std.debug.print("       git clone {s}{s}{s} {s} && git -C {3s} checkout {s}\n", .{ self.url, branch_args[0], branch_args[1], path, self.sha });
            std.os.exit(1);
        };

        // TODO: check if the SHA matches an print a message and/or warning if it is different

        return path;
    }

    pub fn resolveOneFile(self: GitRepo, allocator: *std.mem.Allocator, index_sub_path: []const u8) ![]const u8 {
        const repo_path = try self.resolve(allocator);
        defer allocator.free(repo_path);
        return try std.fs.path.join(allocator, &[_][]const u8{ repo_path, index_sub_path });
    }
};
