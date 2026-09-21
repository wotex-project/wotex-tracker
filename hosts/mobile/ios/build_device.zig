const graph = @import("build_graph.zig");
const std = @import("std");

pub fn build(b: *std.Build) void {
    graph.build(b, .device);
}
