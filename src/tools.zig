const std = @import("std");
const ErrorReport = @import("errors.zig").ErrorReport;
const Models = @import("models.zig");
const Json = @import("json_utils.zig").Json;
const Defaults = @import("config.zig").Defaults;

pub fn freeToolCallList(allocator: std.mem.Allocator, calls: []const Models.ToolCall) void {
    for (calls) |*call| {
        allocator.free(call.id);
        allocator.free(call.type);
        allocator.free(call.function.name);
        allocator.free(call.function.arguments);
    }

    if (calls.len > 0) {
        allocator.free(calls);
    }
}

pub fn freeConversationMessage(allocator: std.mem.Allocator, message: *const Models.Message) void {
    if (message.content) |content| {
        allocator.free(content);
    }

    if (message.tool_call_id) |tool_call_id| {
        allocator.free(tool_call_id);
    }

    if (message.tool_calls) |tool_calls| {
        freeToolCallList(allocator, tool_calls);
    }
}

fn isUnsafeToolPath(path: []const u8) bool {
    if (path.len == 0) return true;

    if (std.fs.path.isAbsolute(path)) {
        return true;
    }

    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |segment| {
        if (segment.len == 2 and std.mem.eql(u8, segment, "..")) {
            return true;
        }
    }

    return false;
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn readRequestedFile(allocator: std.mem.Allocator, diag: *ErrorReport, requested_path: []const u8) ![]u8 {
    if (isUnsafeToolPath(requested_path)) {
        try diag.setf(.tool, "Tool read path is not allowed: '{s}'", .{requested_path});
        return error.InvalidToolArguments;
    }

    const attempted = readFileAll(allocator, requested_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try diag.setf(.filesystem, "Failed to open '{s}': {any}", .{ requested_path, err });
            return error.FileSystemError;
        },
    };

    if (attempted) |contents| return contents;

    // Backward-compatible fallback for bare filenames (no path separators): src/<filename>.
    const looks_like_bare_name =
        std.mem.indexOfScalar(u8, requested_path, '/') == null and
        std.mem.indexOfScalar(u8, requested_path, '\\') == null;

    if (!looks_like_bare_name) {
        try diag.setf(.filesystem, "File not found: '{s}'", .{requested_path});
        return error.RequestedFileNotFound;
    }

    const src_path = try std.fmt.allocPrint(allocator, "src/{s}", .{requested_path});
    defer allocator.free(src_path);

    const from_src = readFileAll(allocator, src_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            try diag.setf(.filesystem, "Failed to open '{s}': {any}", .{ src_path, err });
            return error.FileSystemError;
        },
    };

    if (from_src) |contents| return contents;

    try diag.setf(.filesystem, "File not found: '{s}' (also checked '{s}')", .{ requested_path, src_path });
    return error.RequestedFileNotFound;
}

pub fn parseToolArgumentsToPath(allocator: std.mem.Allocator, diag: *ErrorReport, args_raw: []const u8) ![]const u8 {
    var parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{}) catch |err| {
        try diag.setf(.json, "Failed to parse tool arguments JSON: {any}", .{err});
        return error.JsonError;
    };
    defer parsed_args.deinit();

    const args_obj = try Json.asObject(diag, parsed_args.value, "tool_arguments");
    const file_path = try Json.asString(diag, try Json.field(diag, args_obj, Defaults.read_file_param), "tool_arguments.file_path");

    return try allocator.dupe(u8, file_path);
}

pub fn parseAssistantMessage(allocator: std.mem.Allocator, diag: *ErrorReport, message_obj: std.json.ObjectMap) !Models.ParsedAssistantMessage {
    var content: ?[]const u8 = null;
    if (message_obj.get("content")) |content_raw| {
        switch (content_raw) {
            .string => content = try allocator.dupe(u8, content_raw.string),
            .null => content = null,
            else => {
                try diag.setf(.json, "Expected assistant content to be a string or null, got {any}", .{content_raw});
                return error.InvalidType;
            },
        }
    }

    var tool_calls_out: ?[]const Models.ToolCall = null;

    if (message_obj.get("tool_calls")) |tool_calls_raw| {
        if (tool_calls_raw != .null) {
            const tool_call_array = try Json.asArray(diag, tool_calls_raw, "assistant.message.tool_calls");

            if (tool_call_array.items.len == 0) {
                tool_calls_out = null;
            } else {
                var calls = std.ArrayList(Models.ToolCall){};
                errdefer {
                    for (calls.items) |*call| {
                        allocator.free(call.function.name);
                        allocator.free(call.function.arguments);
                        allocator.free(call.id);
                        allocator.free(call.type);
                    }
                    calls.deinit(allocator);
                }

                for (tool_call_array.items) |item| {
                    const call_obj = try Json.asObject(diag, item, "assistant.message.tool_calls[]");
                    const call_id_raw = try Json.asString(diag, try Json.field(diag, call_obj, "id"), "assistant.message.tool_calls[].id");
                    const call_type = try Json.asString(diag, try Json.field(diag, call_obj, "type"), "assistant.message.tool_calls[].type");
                    if (!std.mem.eql(u8, call_type, Defaults.read_tool_type)) {
                        try diag.setf(.tool, "Unsupported tool call type '{s}'", .{call_type});
                        return error.InvalidToolCallsShape;
                    }

                    const function_obj = try Json.asObject(diag, try Json.field(diag, call_obj, "function"), "assistant.message.tool_calls[].function");
                    const function_name = try Json.asString(diag, try Json.field(diag, function_obj, "name"), "assistant.message.tool_calls[].function.name");
                    if (!std.mem.eql(u8, function_name, Defaults.read_tool_name)) {
                        try diag.setf(.tool, "Unsupported tool function '{s}'", .{function_name});
                        return error.UnsupportedFunction;
                    }

                    const args_raw = try Json.asString(diag, try Json.field(diag, function_obj, "arguments"), "assistant.message.tool_calls[].function.arguments");

                    try calls.append(allocator, .{
                        .id = try allocator.dupe(u8, call_id_raw),
                        .type = try allocator.dupe(u8, call_type),
                        .function = .{
                            .name = try allocator.dupe(u8, function_name),
                            .arguments = try allocator.dupe(u8, args_raw),
                        },
                    });
                }

                if (calls.items.len == 0) {
                    calls.deinit(allocator);
                    tool_calls_out = null;
                } else {
                    tool_calls_out = try calls.toOwnedSlice(allocator);
                }
            }
        }
    }

    return .{ .content = content, .tool_calls = tool_calls_out };
}

pub fn executeToolCall(allocator: std.mem.Allocator, diag: *ErrorReport, call_index: usize, tool_call: Models.ToolCall) ![]u8 {
    const function = tool_call.function;
    if (!std.mem.eql(u8, function.name, Defaults.read_tool_name)) {
        try diag.setf(.tool, "Unsupported tool call #{d} (id={s}): function '{s}' is not supported", .{
            call_index,
            tool_call.id,
            function.name,
        });
        return error.UnsupportedFunction;
    }

    const file_path = parseToolArgumentsToPath(allocator, diag, function.arguments) catch |err| {
        try diag.setf(.tool, "Tool call #{d} (id={s}) arguments are invalid: {any}", .{ call_index, tool_call.id, err });
        return err;
    };
    defer allocator.free(file_path);

    return readRequestedFile(allocator, diag, file_path) catch |err| {
        try diag.setf(.tool, "Tool call #{d} (id={s}) failed to read '{s}': {any}", .{ call_index, tool_call.id, file_path, err });
        return err;
    };
}
