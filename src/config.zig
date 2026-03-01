const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;

pub const Config = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

pub const Defaults = struct {
    pub const default_base_url = "https://openrouter.ai/api/v1";
    pub const default_openai_model = "anthropic/claude-haiku-4.5";
    pub const default_deepseek_model = "deepseek-chat";

    pub const read_tool_name = "Read";
    pub const read_tool_type = "function";
    pub const read_file_param = "file_path";
    pub const read_tool_description = "Read and return the contents of a file";
    pub const max_agent_iterations: u8 = 16;
    pub const max_tool_read_bytes: usize = 1024 * 1024;
    pub const max_tool_calls_per_iteration: usize = 8;
    pub const default_tool_allowed_dirs: []const []const u8 = &[_][]const u8{"src"};
};

pub fn maxToolReadBytes() usize {
    const raw = std.posix.getenv("CLAUDE_TOOL_MAX_BYTES") orelse return Defaults.max_tool_read_bytes;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return Defaults.max_tool_read_bytes;
    return if (parsed == 0) Defaults.max_tool_read_bytes else parsed;
}

/// Maximum number of tool calls allowed per assistant message.
pub fn maxToolCallsPerIteration() usize {
    const raw = std.posix.getenv("CLAUDE_AGENT_MAX_TOOL_CALLS") orelse return Defaults.max_tool_calls_per_iteration;
    const parsed = std.fmt.parseInt(usize, raw, 10) catch return Defaults.max_tool_calls_per_iteration;
    if (parsed == 0) return Defaults.max_tool_calls_per_iteration;
    return parsed;
}

/// Return configured allowed directories for `Read` tool path inputs.
pub fn allowedToolDirs(allocator: std.mem.Allocator) ![][]const u8 {
    const raw = std.posix.getenv("CLAUDE_TOOL_ALLOWED_DIRS") orelse {
        return try cloneStringSlice(allocator, Defaults.default_tool_allowed_dirs);
    };

    var out = std.ArrayList([]const u8){};
    errdefer {
        for (out.items) |item| {
            allocator.free(item);
        }
        out.deinit(allocator);
    }

    var it = std.mem.splitAny(u8, raw, ",");
    while (it.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, trimmed));
    }

    if (out.items.len == 0) {
        return try cloneStringSlice(allocator, Defaults.default_tool_allowed_dirs);
    }

    return try out.toOwnedSlice(allocator);
}

/// Release a list allocated by allowedToolDirs.
pub fn freeStringList(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |item| {
        allocator.free(item);
    }
    allocator.free(list);
}

fn cloneStringSlice(allocator: std.mem.Allocator, values: []const []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8){};
    errdefer {
        for (out.items) |item| {
            allocator.free(item);
        }
        out.deinit(allocator);
    }

    for (values) |value| {
        try out.append(allocator, try allocator.dupe(u8, value));
    }

    return try out.toOwnedSlice(allocator);
}

/// Enable verbose diagnostics for request/response lifecycle tracing.
pub fn isDebugEnabled() bool {
    const raw = std.posix.getenv("CLAUDE_AGENT_DEBUG") orelse return false;
    if (raw.len == 0) return false;

    return std.mem.eql(u8, raw, "1") or
        std.mem.eql(u8, raw, "true") or
        std.mem.eql(u8, raw, "TRUE") or
        std.mem.eql(u8, raw, "True") or
        std.mem.eql(u8, raw, "yes") or
        std.mem.eql(u8, raw, "YES") or
        std.mem.eql(u8, raw, "on") or
        std.mem.eql(u8, raw, "ON");
}

pub fn loadConfig(diag: *ErrorReport) !Config {
    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse {
        diag.setBorrowed(.config, "Missing environment variable OPENROUTER_API_KEY");
        return error.MissingApiKey;
    };

    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse Defaults.default_base_url;
    const default_model = if (std.mem.indexOf(u8, base_url, "deepseek") != null)
        Defaults.default_deepseek_model
    else
        Defaults.default_openai_model;

    return .{
        .api_key = api_key,
        .base_url = base_url,
        .model = std.posix.getenv("OPENROUTER_MODEL") orelse default_model,
    };
}

/// Maximum number of assistant/tool loop iterations.
/// Can be overridden with CLAUDE_AGENT_MAX_ITERATIONS.
pub fn maxAgentIterations() u8 {
    const raw = std.posix.getenv("CLAUDE_AGENT_MAX_ITERATIONS") orelse return Defaults.max_agent_iterations;
    const parsed = std.fmt.parseInt(u8, raw, 10) catch return Defaults.max_agent_iterations;
    return if (parsed == 0) Defaults.max_agent_iterations else parsed;
}
