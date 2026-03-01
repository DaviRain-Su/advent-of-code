const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;

pub fn parsePrompt(allocator: std.mem.Allocator, diag: *ErrorReport) ![]u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        diag.setBorrowed(.usage, "Usage: main -p <prompt...>");
        return error.UsageError;
    }

    return try std.mem.join(allocator, " ", args[2..]);
}

pub fn writeAll(diag: *ErrorReport, data: []const u8) !void {
    std.fs.File.stdout().writeAll(data) catch {
        diag.setBorrowed(.output, "Failed to write output to stdout");
        return error.WriteFailed;
    };
}
