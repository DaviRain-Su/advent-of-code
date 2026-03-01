const std = @import("std");

const ErrorReport = @import("errors.zig").ErrorReport;
const ConfigMod = @import("config.zig");
const Agent = @import("agent.zig");
const Prompt = @import("prompt.zig");

pub fn runWithPrompt(diag: *ErrorReport, prompt: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = ConfigMod.loadConfig(diag) catch |err| {
        return err;
    };

    try Agent.runAgent(allocator, diag, config, prompt);
}

pub fn run(diag: *ErrorReport) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = Prompt.parsePrompt(allocator, diag) catch |err| {
        switch (err) {
            error.UsageError => return err,
            else => {
                diag.setBorrowed(.validation, "Unexpected error while reading command-line arguments");
                return error.UsageError;
            },
        }
    };
    defer allocator.free(prompt);

    const config = ConfigMod.loadConfig(diag) catch |err| {
        return err;
    };

    try Agent.runAgent(allocator, diag, config, prompt);
}
