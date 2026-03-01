const std = @import("std");

const Config = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    fn fromEnv() Config {
        const api_key = std.posix.getenv("OPENROUTER_API_KEY") orelse @panic("OPENROUTER_API_KEY is not set");
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
    fn field(obj: std.json.ObjectMap, key: []const u8) std.json.Value {
        return obj.get(key) orelse @panic("Expected field in response JSON");
    }

    fn asString(value: std.json.Value) []const u8 {
        if (value != .string) @panic("Expected string in response JSON");
        return value.string;
    }

    fn asArray(value: std.json.Value) std.json.Array {
        if (value != .array) @panic("Expected array in response JSON");
        return value.array;
    }

    fn asObject(value: std.json.Value) std.json.ObjectMap {
        if (value != .object) @panic("Expected object in response JSON");
        return value.object;
    }
};

fn parsePrompt(allocator: std.mem.Allocator) ![]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        @panic("Usage: main -p <prompt>");
    }

    return try allocator.dupe(u8, args[2]);
}

fn writeAllOrPanic(data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch @panic("Failed to write output");
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn readRequestedFile(allocator: std.mem.Allocator, requested_path: []const u8) ![]u8 {
    // First try exactly the path returned by the model.
    if (readFileAll(allocator, requested_path)) |contents| {
        return contents;
    } else |err| {
        if (err != error.FileNotFound) return err;
    }

    // Keep the current compatibility behavior: bare filenames (no path separators)
    // can fall back to src/<filename>.
    const looksLikeBareName =
        std.mem.indexOfScalar(u8, requested_path, '/') == null and
        std.mem.indexOfScalar(u8, requested_path, '\\') == null;
    if (!looksLikeBareName) return error.FileNotFound;

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

fn checkApiError(response_obj: std.json.ObjectMap) void {
    if (response_obj.get("error")) |error_obj| {
        if (error_obj == .string) {
            @panic(error_obj.string);
        }
        if (error_obj == .object) {
            if (error_obj.object.get("message")) |msg| {
                if (msg == .string) {
                    @panic(msg.string);
                }
            }
        }
        @panic("Request failed");
    }
}

fn parseReadToolPath(allocator: std.mem.Allocator, tool_calls: std.json.Value) ![]const u8 {
    const tool_call_list = Json.asArray(tool_calls);
    if (tool_call_list.items.len == 0) {
        @panic("Empty tool_calls array");
    }

    const first_tool_call = Json.asObject(tool_call_list.items[0]);
    const function_obj = Json.asObject(Json.field(first_tool_call, "function"));
    const function_name = Json.asString(Json.field(function_obj, "name"));

    if (!std.mem.eql(u8, function_name, Defaults.read_tool_name)) {
        @panic("Unsupported function");
    }

    const args_raw = Json.asString(Json.field(function_obj, "arguments"));
    var parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{});
    defer parsed_args.deinit();

    const args_obj = Json.asObject(parsed_args.value);
    const file_path = Json.asString(Json.field(args_obj, Defaults.read_file_param));
    return try allocator.dupe(u8, file_path);
}

fn parseAssistantAction(allocator: std.mem.Allocator, message: std.json.ObjectMap) !AssistantAction {
    if (message.get("tool_calls")) |tool_calls| {
        if (tool_calls == .null) return .none;
        if (tool_calls != .array) @panic("tool_calls is not an array");

        const file_path = try parseReadToolPath(allocator, tool_calls);
        return .{ .read_file = file_path };
    }

    const content = Json.field(message, "content");
    if (content == .string) {
        return .{ .reply_text = content.string };
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
        .reply_text => |text| writeAllOrPanic(text),
        .read_file => |path| {
            const file_contents = readRequestedFile(allocator, path) catch |err| {
                if (err == error.FileNotFound) {
                    @panic("Failed to read requested file path");
                }
                return err;
            };
            defer allocator.free(file_contents);
            writeAllOrPanic(file_contents);
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = try parsePrompt(allocator);
    defer allocator.free(prompt);

    const config = Config.fromEnv();
    const response_body = try sendCompletionRequest(allocator, config, prompt);
    defer allocator.free(response_body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const response_obj = Json.asObject(parsed.value);
    checkApiError(response_obj);

    const choices = Json.asArray(Json.field(response_obj, "choices"));
    if (choices.items.len == 0) @panic("No choices in response");

    const first_choice = Json.asObject(choices.items[0]);
    const message = Json.asObject(Json.field(first_choice, "message"));

    const action = try parseAssistantAction(allocator, message);
    defer freeAssistantAction(allocator, action);

    try executeAssistantAction(allocator, action);
}
