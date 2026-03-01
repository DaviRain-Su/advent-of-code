const std = @import("std");

const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const App = @import("app.zig");
const Prompt = @import("prompt.zig");
const Tui = @import("tui/tui.zig");

// Capture panic traces to a file so TUI crashes can be diagnosed even when
// terminal output is disrupted.
pub const panic = std.debug.FullPanic(struct {
    fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (std.fs.cwd().createFile("/tmp/claude_tui_crash.log", .{}) catch null) |file| {
            defer file.close();
            var out_buf: [4096]u8 = undefined;
            const msg_line = std.fmt.bufPrint(&out_buf, "[panic] {s}\n", .{msg}) catch "[panic] <format error>\n";
            _ = file.write(msg_line) catch {};
            _ = file.write("trace: ") catch {};
            _ = file.write("(incomplete, see stderr)\n") catch {};
        }

        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

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
        App.runWithPrompt(allocator, &diagnostics, prompt, null, null, null) catch |err| {
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
