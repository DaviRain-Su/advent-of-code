const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;
const ConfigMod = @import("config.zig");
const Models = @import("models.zig");
const Config = ConfigMod.Config;

pub fn buildRequestBody(allocator: std.mem.Allocator, cfg: Config, messages: []const Models.Message) ![]u8 {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    const tools = [_]struct {
        type: []const u8,
        function: struct {
            name: []const u8,
            description: []const u8,
            parameters: struct {
                type: []const u8,
                properties: struct {
                    file_path: ?struct { type: []const u8, description: []const u8 } = null,
                    content: ?struct { type: []const u8, description: []const u8 } = null,
                    command: ?struct { type: []const u8, description: []const u8 } = null,
                },
                required: []const []const u8,
            },
        },
    }{
        .{
            .type = ConfigMod.Defaults.read_tool_type,
            .function = .{
                .name = ConfigMod.Defaults.read_tool_name,
                .description = ConfigMod.Defaults.read_tool_description,
                .parameters = .{
                    .type = "object",
                    .properties = .{
                        .file_path = .{ .type = "string", .description = "The path to the file to read" },
                        .content = null,
                        .command = null,
                    },
                    .required = &[_][]const u8{ConfigMod.Defaults.read_file_param},
                },
            },
        },
        .{
            .type = ConfigMod.Defaults.read_tool_type,
            .function = .{
                .name = ConfigMod.Defaults.write_tool_name,
                .description = ConfigMod.Defaults.write_tool_description,
                .parameters = .{
                    .type = "object",
                    .properties = .{
                        .file_path = .{ .type = "string", .description = "The path of the file to write to" },
                        .content = .{ .type = "string", .description = "The content to write to the file" },
                        .command = null,
                    },
                    .required = &[_][]const u8{ ConfigMod.Defaults.read_file_param, ConfigMod.Defaults.write_content_param },
                },
            },
        },
        .{
            .type = ConfigMod.Defaults.read_tool_type,
            .function = .{
                .name = ConfigMod.Defaults.bash_tool_name,
                .description = ConfigMod.Defaults.bash_tool_description,
                .parameters = .{
                    .type = "object",
                    .properties = .{
                        .file_path = null,
                        .content = null,
                        .command = .{ .type = "string", .description = "The command to execute" },
                    },
                    .required = &[_][]const u8{ConfigMod.Defaults.bash_command_param},
                },
            },
        },
    };

    var json_writer = std.json.Stringify{ .writer = &body_out.writer, .options = .{ .emit_null_optional_fields = false } };
    try json_writer.write(.{
        .model = cfg.model,
        .messages = messages,
        .tools = &tools,
    });

    return try allocator.dupe(u8, body_out.written());
}

pub fn sendCompletionRequest(allocator: std.mem.Allocator, diag: *ErrorReport, cfg: Config, messages: []const Models.Message) ![]u8 {
    const body = try buildRequestBody(allocator, cfg, messages);
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.base_url});
    defer allocator.free(url);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_out: std.io.Writer.Allocating = .init(allocator);
    defer response_out.deinit();

    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &response_out.writer,
    }) catch |err| {
        try diag.setf(.network, "HTTP request to {s} failed: {any}", .{ url, err });
        return error.HttpError;
    };

    return try allocator.dupe(u8, response_out.written());
}

pub fn checkApiError(diag: *ErrorReport, response_obj: std.json.ObjectMap) !void {
    const error_obj = response_obj.get("error") orelse return;

    if (error_obj == .string) {
        try diag.setf(.api, "Provider response error: {s}", .{error_obj.string});
        return error.ApiError;
    }

    if (error_obj == .object) {
        const err_obj = error_obj.object;

        if (err_obj.get("message")) |msg| {
            if (msg == .string) {
                var code_buf: ?[]const u8 = null;
                if (err_obj.get("code")) |code| {
                    if (code == .string) {
                        code_buf = code.string;
                    }
                }

                if (code_buf) |code| {
                    try diag.setf(.api, "Provider API error [{s}]: {s}", .{ code, msg.string });
                } else {
                    try diag.setf(.api, "Provider API error: {s}", .{msg.string});
                }
                return error.ApiError;
            }
        }

        if (err_obj.get("type")) |typ| {
            if (typ == .string) {
                try diag.setf(.api, "Provider API error type: {s}", .{typ.string});
                return error.ApiError;
            }
        }

        return error.ApiError;
    }

    diag.setBorrowed(.api, "Provider returned an error payload in an unexpected JSON shape");
    return error.ApiError;
}
