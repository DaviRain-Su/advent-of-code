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
};

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
