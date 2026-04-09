const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("zigenet", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zigenet",
        .root_module = lib_mod,
    });
    lib.use_llvm = true;
    lib.linkLibC();
    if (target.result.os.tag == .windows) lib.linkSystemLibrary("ws2_32");
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.use_llvm = true;
    tests.linkLibC();
    if (target.result.os.tag == .windows) tests.linkSystemLibrary("ws2_32");

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "run library tests");
    test_step.dependOn(&run_tests.step);

    inline for ([_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "zigenet-server", .path = "examples/server.zig" },
        .{ .name = "zigenet-client", .path = "examples/client.zig" },
    }) |example| {
        const exe = b.addExecutable(.{
            .name = example.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(example.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.use_llvm = true;
        exe.linkLibC();
        if (target.result.os.tag == .windows) exe.linkSystemLibrary("ws2_32");
        exe.root_module.addImport("zigenet", lib_mod);
        b.installArtifact(exe);
    }

    const parity = b.addExecutable(.{
        .name = "parity-harness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/parity.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
    });
    parity.root_module.addImport("zigenet", lib_mod);
    parity.linkLibC();
    if (target.result.os.tag == .windows) parity.linkSystemLibrary("ws2_32");
    b.installArtifact(parity);
}
