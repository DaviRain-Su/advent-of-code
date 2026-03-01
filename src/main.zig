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
    FileSystemError,
    WriteFailed,
    HttpError,
    JsonError,
    ApiError,
};

const ErrorCategory = enum {
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

const ErrorReport = struct {
    allocator: std.mem.Allocator,
    kind: ErrorCategory = .none,
    detail: ?[]const u8 = null,
    owned_detail: bool = false,

    fn init(allocator: std.mem.Allocator) ErrorReport {
        return .{ .allocator = allocator };
    }

    fn clear(self: *ErrorReport) void {
        if (self.owned_detail) {
            if (self.detail) |detail| {
                self.allocator.free(detail);
            }
        }
        self.kind = .none;
        self.detail = null;
        self.owned_detail = false;
    }

    fn deinit(self: *ErrorReport) void {
        self.clear();
    }

    fn setBorrowed(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) void {
        self.clear();
        self.kind = kind;
        self.detail = detail;
        self.owned_detail = false;
    }

    fn setOwned(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) void {
        self.clear();
        self.kind = kind;
        self.detail = detail;
        self.owned_detail = true;
    }

    fn set(self: *ErrorReport, kind: ErrorCategory, detail: []const u8) !void {
        const copied = try self.allocator.dupe(u8, detail);
        self.setOwned(kind, copied);
    }

    fn setf(self: *ErrorReport, kind: ErrorCategory, comptime format: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.allocator, format, args);
        self.setOwned(kind, msg);
    }
};

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

const AssistantAction = union(enum) {
    read_file: []const u8,
    reply_text: []const u8,
    none,
};

const Json = struct {
    fn field(diag: *ErrorReport, obj: std.json.ObjectMap, key: []const u8) !std.json.Value {
        return obj.get(key) orelse {
            try diag.setf(.json, "Missing JSON field '{s}'", .{key});
            return error.MissingField;
        };
    }

    fn asString(diag: *ErrorReport, value: std.json.Value, path: []const u8) ![]const u8 {
        if (value != .string) {
            try diag.setf(.json, "Expected JSON string for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.string;
    }

    fn asArray(diag: *ErrorReport, value: std.json.Value, path: []const u8) !std.json.Array {
        if (value != .array) {
            try diag.setf(.json, "Expected JSON array for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.array;
    }

    fn asObject(diag: *ErrorReport, value: std.json.Value, path: []const u8) !std.json.ObjectMap {
        if (value != .object) {
            try diag.setf(.json, "Expected JSON object for '{s}'", .{path});
            return error.InvalidType;
        }
        return value.object;
    }
};

fn loadConfig(diag: *ErrorReport) !Config {
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

fn parsePrompt(allocator: std.mem.Allocator, diag: *ErrorReport) ![]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3 or !std.mem.eql(u8, args[1], "-p")) {
        diag.setBorrowed(.usage, "Usage: main -p <prompt>");
        return error.UsageError;
    }

    return try allocator.dupe(u8, args[2]);
}

fn writeAll(diag: *ErrorReport, data: []const u8) !void {
    std.fs.File.stdout().writeAll(data) catch {
        diag.setBorrowed(.output, "Failed to write output to stdout");
        return error.WriteFailed;
    };
}

fn readFileAll(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn readRequestedFile(allocator: std.mem.Allocator, diag: *ErrorReport, requested_path: []const u8) ![]u8 {
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

fn sendCompletionRequest(allocator: std.mem.Allocator, diag: *ErrorReport, cfg: Config, prompt: []const u8) ![]u8 {
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

fn checkApiError(diag: *ErrorReport, response_obj: std.json.ObjectMap) !void {
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

fn parseReadToolPath(allocator: std.mem.Allocator, diag: *ErrorReport, tool_calls: std.json.Value) ![]const u8 {
    const tool_call_list = try Json.asArray(diag, tool_calls, "tool_calls");

    if (tool_call_list.items.len == 0) {
        diag.setBorrowed(.tool, "tool_calls array is empty");
        return error.EmptyToolCalls;
    }

    const first_tool_call = try Json.asObject(diag, tool_call_list.items[0], "tool_calls[0]");
    const function_obj = try Json.asObject(diag, try Json.field(diag, first_tool_call, "function"), "tool_calls[0].function");
    const function_name = try Json.asString(diag, try Json.field(diag, function_obj, "name"), "tool_calls[0].function.name");

    if (!std.mem.eql(u8, function_name, Defaults.read_tool_name)) {
        try diag.setf(.tool, "Unsupported tool function '{s}'", .{function_name});
        return error.UnsupportedFunction;
    }

    const args_raw = try Json.asString(diag, try Json.field(diag, function_obj, "arguments"), "tool_calls[0].function.arguments");
    var parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args_raw, .{}) catch |err| {
        try diag.setf(.json, "Failed to parse tool arguments JSON: {any}", .{err});
        return error.JsonError;
    };
    defer parsed_args.deinit();

    const args_obj = try Json.asObject(diag, parsed_args.value, "tool_calls[0].function.arguments");
    const file_path = try Json.asString(diag, try Json.field(diag, args_obj, Defaults.read_file_param), "tool_calls[0].function.arguments.file_path");

    return try allocator.dupe(u8, file_path);
}

fn parseAssistantAction(allocator: std.mem.Allocator, diag: *ErrorReport, message: std.json.ObjectMap) !AssistantAction {
    if (message.get("tool_calls")) |tool_calls| {
        if (tool_calls == .null) return .none;

        if (tool_calls != .array) {
            diag.setBorrowed(.tool, "tool_calls exists but is not an array");
            return error.InvalidToolCallsShape;
        }

        const file_path = try parseReadToolPath(allocator, diag, tool_calls);
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

fn executeAssistantAction(allocator: std.mem.Allocator, diag: *ErrorReport, action: AssistantAction) !void {
    switch (action) {
        .none => {},
        .reply_text => |text| try writeAll(diag, text),
        .read_file => |path| {
            const file_contents = readRequestedFile(allocator, diag, path) catch |err| return err;
            defer allocator.free(file_contents);
            try writeAll(diag, file_contents);
        },
    }
}

fn formatErrorCategory(kind: ErrorCategory) []const u8 {
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

fn formatBaseMessage(err: AppError) []const u8 {
    return switch (err) {
        .UsageError => "Usage error",
        .MissingApiKey => "OpenRouter API key is required",
        .MissingField => "Malformed provider response (missing expected JSON field)",
        .InvalidType => "Malformed provider response (unexpected JSON type)",
        .InvalidToolCallsShape => "Malformed tool-calls payload shape",
        .EmptyToolCalls => "Tool calls array is empty",
        .UnsupportedFunction => "Unsupported tool function",
        .NoChoices => "Provider returned no choices",
        .RequestedFileNotFound => "Requested file was not found",
        .FileSystemError => "Could not read file from filesystem",
        .WriteFailed => "Failed to write assistant output",
        .HttpError => "Provider request failed",
        .JsonError => "Failed to parse provider response",
        .ApiError => "Provider returned an API error",
    };
}

fn userFacingMessage(allocator: std.mem.Allocator, err: anyerror, report: *ErrorReport) ![]const u8 {
    const category = formatErrorCategory(report.kind);
    const base = switch (err) {
        error.UsageError => "Usage error",
        error.MissingApiKey => "OpenRouter API key is required",
        error.MissingField => "Malformed provider response (missing expected JSON field)",
        error.InvalidType => "Malformed provider response (unexpected JSON type)",
        error.InvalidToolCallsShape => "Malformed tool-calls payload shape",
        error.EmptyToolCalls => "Tool calls array is empty",
        error.UnsupportedFunction => "Unsupported tool function",
        error.NoChoices => "Provider returned no choices",
        error.RequestedFileNotFound => "Requested file was not found",
        error.FileSystemError => "Could not read file from filesystem",
        error.WriteFailed => "Failed to write assistant output",
        error.HttpError => "Provider request failed",
        error.JsonError => "Failed to parse provider response",
        error.ApiError => "Provider returned an API error",
        else => "Unexpected runtime error",
    };

    if (report.detail) |detail| {
        return try std.fmt.allocPrint(allocator, "[{s}] {s}: {s}", .{ category, base, detail });
    }
    return try std.fmt.allocPrint(allocator, "[{s}] {s}", .{ category, base });
}

fn run(diag: *ErrorReport) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = parsePrompt(allocator, diag) catch |err| {
        switch (err) {
            error.UsageError => return err,
            else => {
                diag.setBorrowed(.validation, "Unexpected error while reading command-line arguments");
                return error.UsageError;
            },
        }
    };
    defer allocator.free(prompt);

    const config = loadConfig(diag) catch |err| {
        return err;
    };

    const response_body = sendCompletionRequest(allocator, diag, config, prompt) catch |err| {
        switch (err) {
            error.HttpError => return err,
            else => {
                diag.setf(.network, "Unexpected network error: {any}", .{err}) catch {};
                return error.HttpError;
            },
        }
    };
    defer allocator.free(response_body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch |err| {
        try diag.setf(.json, "Unable to decode provider JSON response body: {any}", .{err});
        return error.JsonError;
    };
    defer parsed.deinit();

    const response_obj = try Json.asObject(diag, parsed.value, "response");
    try checkApiError(diag, response_obj);

    const choices = try Json.asArray(diag, try Json.field(diag, response_obj, "choices"), "response.choices");
    if (choices.items.len == 0) {
        diag.setBorrowed(.validation, "No choices were returned in API response");
        return error.NoChoices;
    }

    const first_choice = try Json.asObject(diag, choices.items[0], "response.choices[0]");
    const message = try Json.asObject(diag, try Json.field(diag, first_choice, "message"), "response.choices[0].message");

    const action = parseAssistantAction(allocator, diag, message) catch |err| return err;
    defer freeAssistantAction(allocator, action);

    try executeAssistantAction(allocator, diag, action);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var diagnostics = ErrorReport.init(allocator);
    defer diagnostics.deinit();

    run(&diagnostics) catch |err| {
        const msg = switch (err) {
            error.UsageError,
            error.MissingApiKey,
            error.MissingField,
            error.InvalidType,
            error.InvalidToolCallsShape,
            error.EmptyToolCalls,
            error.UnsupportedFunction,
            error.NoChoices,
            error.RequestedFileNotFound,
            error.FileSystemError,
            error.WriteFailed,
            error.HttpError,
            error.JsonError,
            error.ApiError,
            => userFacingMessage(allocator, err, &diagnostics) catch "[Internal] Failed to format error message",
            else => "Unexpected runtime error",
        };

        _ = std.fs.File.stderr().writeAll(msg) catch {};
        _ = std.fs.File.stderr().writeAll("\n") catch {};
        std.process.exit(1);
    };
}
