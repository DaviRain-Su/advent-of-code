const std = @import("std");

const Config = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

const Defaults = struct {
    const default_base_url = "https://openrouter.ai/api/v1";
    const default_openai_model = "anthropic/claude-haiku-4.5";
    const default_deepseek_model = "deepseek-chat";
    const read_tool_name = "Read";
    const read_file_param = "file_path";
    const read_tool_description = "Read and return the contents of a file";
};

fn parsePrompt(allocator: std.mem.Allocator) ![]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        @panic("Usage: main -p <prompt>");
    }

    return try allocator.dupe(u8, args[2]);
}

fn loadConfig() Config {
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

fn requireField(obj: std.json.ObjectMap, key: []const u8) std.json.Value {
    return obj.get(key) orelse @panic("Expected field in response JSON");
}

fn asString(v: std.json.Value) []const u8 {
    if (v != .string) @panic("Expected string in response JSON");
    return v.string;
}

fn asArray(v: std.json.Value) std.json.Array {
    if (v != .array) @panic("Expected array in response JSON");
    return v.array;
}

fn asObject(v: std.json.Value) std.json.ObjectMap {
    if (v != .object) @panic("Expected object in response JSON");
    return v.object;
}

fn buildRequestBody(allocator: std.mem.Allocator, model: []const u8, prompt: []const u8) ![]u8 {
    var body_out: std.io.Writer.Allocating = .init(allocator);
    defer body_out.deinit();

    var jw = std.json.Stringify{ .writer = &body_out.writer };
    try jw.write(.{
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

fn throwOnApiError(response_obj: std.json.ObjectMap) void {
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

    const is_relative_like =
        std.mem.indexOfScalar(u8, requested_path, '/') == null and
        std.mem.indexOfScalar(u8, requested_path, '\\') == null;
    if (!is_relative_like) return error.FileNotFound;

    const src_path = try std.fmt.allocPrint(allocator, "src/{s}", .{requested_path});
    defer allocator.free(src_path);

    return readFileAll(allocator, src_path);
}

fn extractReadToolFilePath(tool_calls: std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    const tool_call_list = asArray(tool_calls);

    if (tool_call_list.items.len == 0) {
        @panic("Empty tool_calls array");
    }

    const first_tool = asObject(tool_call_list.items[0]);
    const function_obj = asObject(requireField(first_tool, "function"));
    const fn_name = asString(requireField(function_obj, "name"));

    if (!std.mem.eql(u8, fn_name, Defaults.read_tool_name)) {
        @panic("Unsupported function");
    }

    const args_raw = asString(requireField(function_obj, "arguments"));
    var parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{});
    defer parsed_args.deinit();

    const args_obj = asObject(parsed_args.value);
    return asString(requireField(args_obj, Defaults.read_file_param));
}

fn maybeReadToolCall(allocator: std.mem.Allocator, message: std.json.ObjectMap) !bool {
    const tool_calls = message.get("tool_calls") orelse return false;
    if (tool_calls == .null) return false;
    if (tool_calls != .array) @panic("tool_calls is not an array");

    const file_path = try extractReadToolFilePath(tool_calls, allocator);

    const file_contents = readRequestedFile(allocator, file_path) catch |err| {
        if (err == error.FileNotFound) @panic("Failed to read requested file path");
        return err;
    };
    defer allocator.free(file_contents);

    try std.fs.File.stdout().writeAll(file_contents);
    return true;
}

fn printTextContent(message: std.json.ObjectMap) void {
    const content = requireField(message, "content");
    if (content == .string) {
        std.fs.File.stdout().writeAll(content.string) catch @panic("Failed to write output");
    }
}

fn handleAssistantMessage(allocator: std.mem.Allocator, message: std.json.ObjectMap) !void {
    if (try maybeReadToolCall(allocator, message)) return;
    printTextContent(message);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = try parsePrompt(allocator);
    defer allocator.free(prompt);

    const config = loadConfig();
    const response_body = try sendCompletionRequest(allocator, config, prompt);
    defer allocator.free(response_body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_body, .{});
    defer parsed.deinit();

    const response_obj = asObject(parsed.value);
    throwOnApiError(response_obj);

    const choices = asArray(requireField(response_obj, "choices"));
    if (choices.items.len == 0) @panic("No choices in response");

    const first_choice = asObject(choices.items[0]);
    const message = asObject(requireField(first_choice, "message"));

    try handleAssistantMessage(allocator, message);
}
