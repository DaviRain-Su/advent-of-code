const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;
const ConfigMod = @import("config.zig");
const Models = @import("models.zig");
const Config = ConfigMod.Config;

pub const StreamSink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void,
};

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

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "user-agent", .value = "codecrafters-claude-code-zig" },
        },
        .response_writer = &response_out.writer,
    }) catch |err| {
        try diag.setf(.network, "HTTP request to {s} failed: {any}", .{ url, err });
        return error.HttpError;
    };

    if (result.status.class() != .success) {
        const body_text = response_out.written();
        if (body_text.len > 0) {
            try diag.setf(.api, "HTTP {d} from {s}: {s}", .{
                @intFromEnum(result.status),
                url,
                body_text,
            });
        } else {
            try diag.setf(.api, "HTTP {d} from {s} without response body", .{ @intFromEnum(result.status), url });
        }

        return error.HttpError;
    }

    return try allocator.dupe(u8, response_out.written());
}

pub fn sendCompletionRequestStreaming(
    allocator: std.mem.Allocator,
    diag: *ErrorReport,
    cfg: Config,
    messages: []const Models.Message,
    sink: ?StreamSink,
) ![]u8 {
    const body = try buildStreamingRequestBody(allocator, cfg, messages);
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.base_url});
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);
    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .extra_headers = &.{
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
            .{ .name = "user-agent", .value = "codecrafters-claude-code-zig" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    req.sendBodyComplete(body) catch |err| {
        try diag.setf(.network, "HTTP request to {s} failed while sending body: {any}", .{ url, err });
        return error.HttpError;
    };

    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buffer) catch |err| {
        try diag.setf(.network, "HTTP request to {s} failed to read response head: {any}", .{ url, err });
        return error.HttpError;
    };

    if (response.head.status.class() != .success) {
        var err_body_out: std.io.Writer.Allocating = .init(allocator);
        defer err_body_out.deinit();

        const error_reader = response.reader(&.{});
        _ = error_reader.streamRemaining(&err_body_out.writer) catch |err| {
            try diag.setf(.network, "HTTP {d} {s} returned from {s}, and body read failed: {any}", .{ @intFromEnum(response.head.status), response.head.reason, url, err });
            return error.HttpError;
        };

        const err_body = err_body_out.written();
        if (err_body.len > 0) {
            try diag.setf(.api, "HTTP {d} {s}: {s}", .{ @intFromEnum(response.head.status), response.head.reason, err_body });
        } else {
            try diag.setf(.api, "HTTP {d} {s} without response body", .{ @intFromEnum(response.head.status), response.head.reason });
        }
        return error.HttpError;
    }

    var content = std.ArrayList(u8){};
    defer content.deinit(allocator);

    var line_out: [64]u8 = undefined;
    const decompressor = response.head.content_encoding;
    var decompress: std.http.Decompress = undefined;
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var zstd_buffer: [std.compress.zstd.default_window_len]u8 = undefined;

    const response_reader = switch (decompressor) {
        .identity => response.reader(&line_out),
        .zstd => response.readerDecompressing(&line_out, &decompress, &zstd_buffer),
        .deflate, .gzip => response.readerDecompressing(&line_out, &decompress, &flate_buffer),
        else => return error.HttpError,
    };

    while (true) {
        const event_line = response_reader.takeDelimiterInclusive('\n') catch |err| {
            switch (err) {
                error.EndOfStream => break,
                else => return error.HttpError,
            }
        };
        const trimmed = std.mem.trimRight(u8, event_line, "\r\n");
        if (trimmed.len == 0) continue;

        if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
        const payload = std.mem.trimLeft(u8, trimmed["data:".len..], " ");
        if (payload.len == 0) continue;
        if (std.mem.eql(u8, payload, "[DONE]")) break;

        const event_value = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
            try diag.setf(.json, "Unable to decode SSE event: {any}", .{err});
            return error.JsonError;
        };
        defer event_value.deinit();

        const event_obj = event_value.value.object;
        try checkApiError(diag, event_obj);

        if (event_obj.get("choices")) |choices_raw| {
            if (choices_raw != .array) {
                try diag.setf(.json, "Invalid SSE event schema: choices must be array", .{});
                return error.JsonError;
            }

            for (choices_raw.array.items) |choice| {
                if (choice != .object) {
                    try diag.setf(.json, "Invalid SSE event schema: choice must be object", .{});
                    return error.JsonError;
                }

                if (choice.object.get("finish_reason")) |finish_raw| {
                    if (finish_raw == .string and std.mem.eql(u8, finish_raw.string, "tool_calls")) {
                        return error.StreamingToolCallsUnsupported;
                    }
                }

                const delta = choice.object.get("delta") orelse continue;
                if (delta != .object) {
                    try diag.setf(.json, "Invalid SSE event schema: delta must be object", .{});
                    return error.JsonError;
                }

                if (delta.object.get("tool_calls")) |_| {
                    return error.StreamingToolCallsUnsupported;
                }

                if (delta.object.get("reasoning_content")) |reasoning_raw| {
                    if (reasoning_raw != .string and reasoning_raw != .null) {
                        try diag.setf(.json, "Invalid SSE event schema: reasoning_content must be string or null", .{});
                        return error.JsonError;
                    }
                }

                if (delta.object.get("content")) |content_raw| {
                    if (content_raw != .string) continue;
                    if (content_raw.string.len == 0) continue;

                    try content.appendSlice(allocator, content_raw.string);
                    if (sink) |stream_sink| {
                        try stream_sink.write(stream_sink.ctx, content_raw.string);
                    }
                }
            }
        }
    }

    return try content.toOwnedSlice(allocator);
}

fn buildStreamingRequestBody(
    allocator: std.mem.Allocator,
    cfg: Config,
    messages: []const Models.Message,
) ![]u8 {
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
        .stream = true,
    });

    return try allocator.dupe(u8, body_out.written());
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
