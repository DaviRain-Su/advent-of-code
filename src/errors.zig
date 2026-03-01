const std = @import("std");

pub const AppError = error{
    UsageError,
    MissingApiKey,
    MissingField,
    InvalidType,
    InvalidToolCallsShape,
    InvalidToolArguments,
    TooLargeToolOutput,
    TooManyToolCalls,
    ToolExecutionFailed,
    TuiUnavailable,
    UnsupportedFunction,
    NoChoices,
    RequestedFileNotFound,
    FileSystemError,
    WriteFailed,
    HttpError,
    JsonError,
    ApiError,
    AgentLoopExceeded,
};

pub const ErrorCategory = enum {
    none,
    usage,
    config,
    network,
    json,
    api,
    tool,
    filesystem,
    output,
    validation,
    unexpected,
};

pub const ErrorReport = struct {
    allocator: std.mem.Allocator,
    kind: ErrorCategory = .none,
    detail: ?[]const u8 = null,
    owned_detail: bool = false,

    pub fn init(allocator: std.mem.Allocator) ErrorReport {
        return .{ .allocator = allocator };
    }

    pub fn clear(self: *ErrorReport) void {
        if (self.owned_detail) {
            if (self.detail) |detail| {
                self.allocator.free(detail);
            }
        }
        self.kind = .none;
        self.detail = null;
        self.owned_detail = false;
    }

    pub fn deinit(self: *ErrorReport) void {
        self.clear();
    }

    pub fn setBorrowed(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) void {
        self.clear();
        self.kind = kind;
        self.detail = detail;
        self.owned_detail = false;
    }

    pub fn setOwned(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) void {
        self.clear();
        self.kind = kind;
        self.detail = detail;
        self.owned_detail = true;
    }

    pub fn set(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) !void {
        const copied = try self.allocator.dupe(u8, detail);
        self.setOwned(kind, copied);
    }

    pub fn setf(self: *ErrorReport, kind: ErrorCategory, comptime format: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, format, args);
        self.setOwned(kind, msg);
    }
};

pub fn formatErrorCategory(kind: ErrorCategory) []const u8 {
    return switch (kind) {
        .usage => "Usage Error",
        .config => "Configuration Error",
        .network => "HTTP Error",
        .json => "JSON Schema Error",
        .api => "Provider API Error",
        .tool => "Tool Calling Error",
        .filesystem => "Filesystem Error",
        .output => "Output Error",
        .validation => "Validation Error",
        .unexpected => "Unexpected Error",
        .none => "Error",
    };
}

pub fn userFacingMessage(allocator: std.mem.Allocator, err: anyerror, report: *ErrorReport) ![]const u8 {
    const category = formatErrorCategory(report.kind);
    const base = switch (err) {
        error.UsageError => "Usage error",
        error.MissingApiKey => "OpenRouter API key is required",
        error.MissingField => "Malformed provider response (missing expected JSON field)",
        error.InvalidType => "Malformed provider response (unexpected JSON type)",
        error.InvalidToolCallsShape => "Malformed tool-calls payload shape",
        error.InvalidToolArguments => "Tool arguments are invalid",
        error.TooLargeToolOutput => "Tool output exceeded size limit",
        error.TooManyToolCalls => "Too many tool calls in a single response",
        error.ToolExecutionFailed => "Tool execution failed",
        error.TuiUnavailable => "TUI unavailable",
        error.UnsupportedFunction => "Unsupported tool function",
        error.NoChoices => "Provider returned no choices",
        error.RequestedFileNotFound => "Requested file was not found",
        error.FileSystemError => "Could not read file from filesystem",
        error.WriteFailed => "Failed to write assistant output",
        error.HttpError => "Provider request failed",
        error.JsonError => "Failed to parse provider response",
        error.ApiError => "Provider returned an API error",
        error.AgentLoopExceeded => "Agent loop exceeded safety limit",
        else => "Unexpected runtime error",
    };

    if (report.detail) |detail| {
        return try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ category, base, detail });
    }

    return try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ category, base });
}
