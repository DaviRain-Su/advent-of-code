const std = @import("std");

const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const App = @import("app.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diagnostics = ErrorReport.init(allocator);
    defer diagnostics.deinit();

    App.run(&diagnostics) catch |err| {
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
            error.UnsupportedFunction,
            error.NoChoices,
            error.RequestedFileNotFound,
            error.FileSystemError,
            error.WriteFailed,
            error.HttpError,
            error.JsonError,
            error.ApiError,
            error.AgentLoopExceeded,
            => Errors.userFacingMessage(allocator, err, &diagnostics) catch "[Internal] Failed to format error message",
            else => "Unexpected runtime error",
        };

        _ = std.fs.File.stderr().writeAll(msg) catch {};
        _ = std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };
}
