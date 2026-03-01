const std = @import("std");

const ErrorReport = @import("errors.zig").ErrorReport;
const ConfigMod = @import("config.zig");
const Agent = @import("agent.zig");

pub fn runWithPrompt(
    allocator: std.mem.Allocator,
    diag: *ErrorReport,
    prompt: []const u8,
    output: ?*std.ArrayList(u8),
    log_sink: ?Agent.LogSink,
) !void {
    const config = ConfigMod.loadConfig(diag) catch |err| {
        return err;
    };

    try Agent.runAgent(allocator, diag, config, prompt, output, log_sink);
}

pub fn run(diag: *ErrorReport) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = @import("prompt.zig").parsePrompt(allocator, diag) catch |err| {
        switch (err) {
            error.UsageError => return err,
            else => {
                diag.setBorrowed(.validation, "Unexpected error while reading command-line arguments");
                return error.UsageError;
            },
        }
    };
    defer allocator.free(prompt);

    try runWithPrompt(allocator, diag, prompt, null, null);
}
