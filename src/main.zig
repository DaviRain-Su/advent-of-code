const std = @import("std");

const AppError = error{
    UsageError,
    MissingApiKey,
    MissingField,
    InvalidType,
    InvalidToolCallsShape,
    EmptyToolCalls,
    UnsupportedFunction,
    NoChoices,
    RequestedFileNotFound,
    WriteFailed,
    ApiError,
};

const Config = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    fn fromEnv() !Config {
        const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse return error.MissingApiKey;
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
};

const Defaults = struct {
    const default_base_url = "https://openrouter.ai/api/v1";
    const default_openai_model = "anthropic/claude-haiku-4.5";
    const default_deepseek_model = "deepseek-chat";

    const read_tool_name = "Read";
    const read_file_param = "file_path";
    const read_tool_description = "Read and return the contents of a file";
};

const AssistantAction = union(enum) {
    read_file: []const u8,
    reply_text: []const u8,
    none,
};

const Json = struct {
    fn field(obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
        return obj.get(key) orelse error.MissingField;
    }

    fn asString(value: std.json.Value) ![]const u8 {
        if (value != .string) return error.InvalidType;
        return value.string;
    }

    fn asArray(value: std.json.Value) !std.json.Array {
        if (value != .array) return error.InvalidType;
        return value.array;
    }

    fn asObject(value: std.json.Value) !std.json.ObjectMap {
        if (value != .object) return error.InvalidType;
        return value.object;
    }
};

fn parsePrompt(allocator: std.mem.Allocator) ![]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        return error.UsageError;
    }

    return try allocator.dupe(u8, args[2]);
}

fn writeAll(data: []const u8) !void {
    try std.fs.File.stdout().writeAll(data);
}

fn writeErrorf(msg: []const u8) void {
    _ = std.fs.File.stderr().writeAll(msg) catch {};
    _ = std.fs.File.stderr().writeAll("\n") catch {};
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn readRequestedFile(allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
    if (readFileAll(allocator, requested_path)) |contents| {
        return contents;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // Backward-compatible fallback for bare filenames (no path separators): src/<filename>.
    const looksLikeBareName =
        std.mem.indexOfScalar(u8, requested_path, '/') == null and
        std.mem.indexOfScalar(u8, requested_path, '\\') == null;
    if (!looksLikeBareName) return error.RequestedFileNotFound;

    const src_path = try std.fmt.allocPrint(allocator, "src/{s}", .{requested_path});
    defer allocator.free(src_path);

    return readFileAll(allocator, src_path);
}

fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8) ![]u8 {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    var json_writer = std.json.Stringify{ .writer = &body_out.writer };
    try json_writer.write(.{
        .model = model,
        .messages = &[_]struct { role: []const u8, content: []const u8 }{
            .{ .role = "user", .content = prompt },
        },
        .tools = &[_]struct { type: []const u8, function: struct {
            name: []const u8,
            description: []const u8,
            parameters: struct {
                type: []const u8,
                properties: struct { file_path: struct { type: []const u8, description: []const u8 } },
                required: []const []const u8,
            },
        } }{
            .{ .type = "function", .function = .{
                .name = Defaults.read_tool_name,
                .description = Defaults.read_tool_description,
                .parameters = .{
                    .type = "object",
                    .properties = .{ .file_path = .{ .type = "string", .description = "The path to the file to read" } },
                    .required = &[_][]const u8{Defaults.read_file_param},
                },
            } },
        },
    });

    return try allocator.dupe(u8, body_out.written());
}

fn sendCompletionRequest(allocator: std.mem.Allocator, cfg: Config, prompt: []const u8) ![]u8 {
    const body = try buildRequestBody(allocator, cfg.model, prompt);
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{cfg.base_url});
    defer allocator.free(url);

    const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{cfg.api_key});
    defer allocator.free(auth_value);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_out: std.io.Writer.Allocating = .init(allocator);
    defer response_out.deinit();

    _ = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = auth_value },
        },
        .response_writer = &response_out.writer,
    });

    return try allocator.dupe(u8, response_out.written());
}

fn checkApiError(response_obj: std.json.ObjectMap) !void {
    if (response_obj.get("error")) |error_obj| {
        if (error_obj == .string) {
            writeErrorf(error_obj.string);
            return error.ApiError;
        }
        if (error_obj == .object) {
            if (error_obj.object.get("message")) |msg| {
                if (msg == .string) {
                    writeErrorf(msg.string);
                    return error.ApiError;
                }
            }
        }
        writeErrorf("Request failed");
        return error.ApiError;
    }
}

fn parseReadToolPath(allocator: std.mem.Allocator, tool_calls: std.json.Value) ![]const u8 {
    const tool_call_list = try Json.asArray(tool_calls);
    if (tool_call_list.items.len == 0) return error.EmptyToolCalls;

    const first_tool_call = try Json.asObject(tool_call_list.items[0]);
    const function_obj = try Json.asObject(try Json.field(first_tool_call, "function"));
    const function_name = try Json.asString(try Json.field(function_obj, "name"));

    if (!std.mem.eql(u8, function_name, Defaults.read_tool_name)) {
        return error.UnsupportedFunction;
    }

    const args_raw = try Json.asString(try Json.field(function_obj, "arguments"));
    var parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{});
    defer parsed_args.deinit();

    const args_obj = try Json.asObject(parsed_args.value);
    const file_path = try Json.asString(try Json.field(args_obj, Defaults.read_file_param));
    return try allocator.dupe(u8, file_path);
}

fn parseAssistantAction(allocator: std.mem.Allocator, message: std.json.ObjectMap) !AssistantAction {
    if (message.get("tool_calls")) |tool_calls| {
        if (tool_calls == .null) return .none;
        if (tool_calls != .array) return error.InvalidToolCallsShape;

        const file_path = try parseReadToolPath(allocator, tool_calls);
        return .{ .read_file = file_path };
    }

    if (message.get("content")) |content| {
        if (content == .string) {
            return .{ .reply_text = content.string };
        }
    }

    return .none;
}

fn freeAssistantAction(allocator: std.mem.Allocator, action: AssistantAction) void {
    switch (action) {
        .read_file => |path| allocator.free(path),
        else => {},
    }
}

fn executeAssistantAction(allocator: std.mem.Allocator, action: AssistantAction) !void {
    switch (action) {
        .none => {},
        .reply_text => |text| try writeAll(text),
        .read_file => |path| {
            const file_contents = readRequestedFile(allocator, path) catch |err| {
                if (err == error.FileNotFound) return error.RequestedFileNotFound;
                return err;
            };
            defer allocator.free(file_contents);
            try writeAll(file_contents);
        },
    }
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.UsageError => "Usage: main -p <prompt>",
        error.MissingApiKey => "OPENROUTER_API_KEY is not set",
        error.MissingField => "Expected field in response JSON",
        error.InvalidType => "Unexpected response JSON type",
        error.InvalidToolCallsShape => "tool_calls is not an array",
        error.EmptyToolCalls => "Empty tool_calls array",
        error.UnsupportedFunction => "Unsupported function",
        error.NoChoices => "No choices in response",
        error.RequestedFileNotFound => "Failed to read requested file path",
        error.WriteFailed => "Failed to write output",
        error.ApiError => "Request failed",
        else => "Unexpected error",
    };
}

fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = try parsePrompt(allocator);
    defer allocator.free(prompt);

    const config = try Config.fromEnv();
    const response_body = try sendCompletionRequest(allocator, config, prompt);
    defer allocator.free(response_body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const response_obj = try Json.asObject(parsed.value);
    try checkApiError(response_obj);

    const choices = try Json.asArray(try Json.field(response_obj, "choices"));
    if (choices.items.len == 0) return error.NoChoices;

    const first_choice = try Json.asObject(choices.items[0]);
    const message = try Json.asObject(try Json.field(first_choice, "message"));

    const action = try parseAssistantAction(allocator, message);
    defer freeAssistantAction(allocator, action);

    try executeAssistantAction(allocator, action);
}

pub fn main() !void {
    run() catch |err| {
        const msg = errorMessage(err);
        _ = std.fs.File.stderr().writeAll(msg) catch {};
        _ = std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };
}
