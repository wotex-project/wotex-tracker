const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const features = b.addOptions();
    features.addOption(bool, "sqlite_static", false);
    features.addOption(bool, "emlx_static", false);
    features.addOption(bool, "nx_eigen_static", false);
    features.addOption(bool, "tflite_static", false);

    const module = b.createModule(.{
        .root_source_file = b.path("../../priv/generated/driver_tab_ios.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", features);

    const object = b.addObject(.{
        .name = "wotex-ios-driver-table-contract",
        .root_module = module,
    });

    const check = b.step("test", "Compile the generated iOS C-ABI driver table");
    check.dependOn(&object.step);
    b.default_step = check;
}
