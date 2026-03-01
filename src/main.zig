const std = @import("std");

const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const App = @import("app.zig");
const Prompt = @import("prompt.zig");
const Tui = @import("tui.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diagnostics = ErrorReport.init(allocator);
    defer diagnostics.deinit();

    const prompt_opt = Prompt.parsePromptOptional(allocator, &diagnostics) catch |err| {
        const msg = Errors.userFacingMessage(allocator, err, &diagnostics) catch "[Internal] Failed to format error message";
        _ = std.fs.File.stderr().writeAll(msg) catch {};
        _ = std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };

    if (prompt_opt) |prompt| {
        defer allocator.free(prompt);
        App.runWithPrompt(allocator, &diagnostics, prompt, null, null) catch |err| {
            reportError(allocator, &diagnostics, err);
        };
    } else {
        Tui.run(allocator, &diagnostics) catch |err| {
            reportError(allocator, &diagnostics, err);
        };
    }
}

fn reportError(allocator: std.mem.Allocator, diagnostics: *ErrorReport, err: anyerror) void {
    const msg = switch (err) {
        error.UsageError,
        error.MissingApiKey,
        error.MissingField,
        error.InvalidType,
        error.InvalidToolCallsShape,
        error.InvalidToolArguments,
        error.TooLargeToolOutput,
        error.TooManyToolCalls,
        error.ToolExecutionFailed,
        error.TuiUnavailable,
        error.UnsupportedFunction,
        error.NoChoices,
        error.RequestedFileNotFound,
        error.FileSystemError,
        error.WriteFailed,
        error.HttpError,
        error.JsonError,
        error.ApiError,
        error.AgentLoopExceeded,
        => Errors.userFacingMessage(allocator, err, diagnostics) catch "[Internal] Failed to format error message",
        else => "Unexpected runtime error",
    };

    _ = std.fs.File.stderr().writeAll(msg) catch {};
    _ = std.fs.File.stderr().writeAll("\n") catch {};
    std.process.exit(1);
}
