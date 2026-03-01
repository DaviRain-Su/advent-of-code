const std = @import("std");

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        @panic("Usage: main -p <prompt>");
    }
    const prompt_str = args[2];

    const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse "https://openrouter.ai/api/v1";
    const default_model = if (std.mem.indexOf(u8, base_url, "deepseek") != null) "deepseek-chat" else "anthropic/claude-haiku-4.5";
    const model = std.posix.getenv("OPENROUTER_MODEL") orelse default_model;

    // Build request body
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();
    var jw: std.json.Stringify = .{ .writer = &body_out.writer };
    try jw.write(.{
        .model = model,
        .messages = &[_]struct { role: []const u8, content: []const u8 }{
            .{ .role = "user", .content = prompt_str },
        },
        .tools = &[_]struct { type: []const u8, function: struct { name: []const u8, description: []const u8, parameters: struct {
            type: []const u8,
            properties: struct { file_path: struct { type: []const u8, description: []const u8 } },
            required: []const []const u8,
        } } }{
            .{ .type = "function", .function = .{ .name = "Read", .description = "Read and return the contents of a file", .parameters = .{ .type = "object", .properties = .{ .file_path = .{ .type = "string", .description = "The path to the file to read" } }, .required = &[_][]const u8{"file_path"} } } },
        },
    });
    const body = body_out.written();

    // Build URL and auth header
    const url_str = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base_url});
    defer allocator.free(url_str);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
    defer allocator.free(auth_value);

    // Make HTTP request
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_out: std.io.Writer.Allocating = .init(allocator);
    defer response_out.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url_str },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &response_out.writer,
    });
    const response_body = response_out.written();

    // Parse response
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    // Helpful diagnostics if provider returns an error payload.
    if (parsed.value.object.get("error")) |error_obj| {
        if (error_obj == .string) {
            @panic(error_obj.string);
        }
        if (error_obj == .object) {
            if (error_obj.object.get("message")) |err_msg| {
                if (err_msg == .string) {
                    @panic(err_msg.string);
                }
            }
        }
        @panic("Request failed");
    }

    const choices_value = parsed.value.object.get("choices") orelse @panic("No choices in response");
    if (choices_value != .array) {
        @panic("choices is not an array");
    }
    const choices = choices_value.array;
    if (choices.items.len == 0) {
        @panic("No choices in response");
    }

    const choice = choices.items[0];
    if (choice != .object) {
        @panic("choice is not an object");
    }
    const message = choice.object.get("message") orelse @panic("No message in choice");
    if (message != .object) {
        @panic("message is not an object");
    }

    // If tool calls exist, execute the first Read tool call.
    if (message.object.get("tool_calls")) |tool_calls| {
        if (tool_calls == .array) {
            const tool_call_list = tool_calls.array;
            if (tool_call_list.items.len == 0) {
                @panic("Empty tool_calls array");
            }

            const tool_call = tool_call_list.items[0];
            if (tool_call != .object) {
                @panic("tool_call is not an object");
            }

            const function_obj = tool_call.object.get("function") orelse @panic("No function in tool_call");
            if (function_obj != .object) {
                @panic("function is not an object");
            }

            const function_name_value = function_obj.object.get("name") orelse @panic("No function name");
            if (function_name_value != .string) {
                @panic("Function name is not a string");
            }
            if (!std.mem.eql(u8, function_name_value.string, "Read")) {
                @panic("Unsupported function");
            }

            const arguments_value = function_obj.object.get("arguments") orelse @panic("No arguments");
            if (arguments_value != .string) {
                @panic("Arguments are not a string");
            }

            // Parse tool arguments JSON
            const args_parsed = try std.json.parseFromSlice(std.json.Value, allocator, arguments_value.string, .{});
            defer args_parsed.deinit();

            const file_path_value = args_parsed.value.object.get("file_path") orelse @panic("No file_path in arguments");
            if (file_path_value != .string) {
                @panic("file_path is not a string");
            }
            const file_path = file_path_value.string;

            // Read file requested by tool call; if that fails, try common fallback paths.
            var file_contents: ?[]u8 = null;
            defer {
                if (file_contents) |contents| {
                    allocator.free(contents);
                }
            }

            file_contents = readFileAll(allocator, file_path) catch |err| blk: {
                if (err != error.FileNotFound) {
                    return err;
                }
                break :blk null;
            };

            if (file_contents == null and std.mem.indexOf(u8, file_path, "/") == null and std.mem.indexOf(u8, file_path, "\\") == null) {
                const src_path = try std.fmt.allocPrint(allocator, "src/{s}", .{file_path});
                defer allocator.free(src_path);
                file_contents = readFileAll(allocator, src_path) catch |err| blk: {
                    if (err != error.FileNotFound) {
                        return err;
                    }
                    break :blk null;
                };
            }

            const final_contents = file_contents orelse {
                @panic("Failed to read requested file path");
            };
            try std.fs.File.stdout().writeAll(final_contents);
            return;
        } else if (tool_calls != .null) {
            @panic("tool_calls is not an array");
        }
    }

    // No tool calls, output the assistant message content.
    const content_value = message.object.get("content") orelse @panic("No content in response");
    if (content_value == .null) {
        return;
    }
    if (content_value != .string) {
        @panic("Unexpected content type");
    }
    try std.fs.File.stdout().writeAll(content_value.string);
}
