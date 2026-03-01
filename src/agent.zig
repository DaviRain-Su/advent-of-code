const std = @import("std");

const ErrorReport = @import("errors.zig").ErrorReport;
const ConfigMod = @import("config.zig");
const JsonUtils = @import("json_utils.zig").Json;
const Models = @import("models.zig");
const Tools = @import("tools.zig");
const Llm = @import("llm.zig");
const Prompt = @import("prompt.zig");

fn debugf(enabled: bool, comptime fmt: []const u8, args: anytype) !void {
    if (!enabled) return;

    var scratch: [2048]u8 = undefined;
    const msg = std.fmt.bufPrint(&scratch, "[debug] " ++ fmt ++ "\n", args) catch return;
    try std.fs.File.stderr().writeAll(msg);
}

pub const LogSink = struct {
    ctx: *anyopaque,
    write: *const fn (ctx: *anyopaque, msg: []const u8) void,
};

pub const StreamSink = Llm.StreamSink;

fn logSink(sink: ?LogSink, comptime fmt: []const u8, args: anytype) void {
    if (sink) |s| {
        var scratch: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&scratch, fmt, args) catch return;
        s.write(s.ctx, msg);
    }
}

fn logSinkSnippet(sink: ?LogSink, label: []const u8, content: []const u8) void {
    if (sink == null) return;
    const max_len: usize = 200;
    const truncated = content.len > max_len;
    const slice = if (truncated) content[0..max_len] else content;

    var scratch: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &scratch,
        "{s}{s}{s}\n",
        .{ label, slice, if (truncated) "..." else "" },
    ) catch return;
    sink.?.write(sink.?.ctx, msg);
}

pub fn runAgent(
    allocator: std.mem.Allocator,
    diag: *ErrorReport,
    config: ConfigMod.Config,
    prompt: []const u8,
    output: ?*std.ArrayList(u8),
    log_sink: ?LogSink,
    stream_sink: ?StreamSink,
) !void {
    const debug_enabled = ConfigMod.isDebugEnabled();
    const max_tool_calls = ConfigMod.maxToolCallsPerIteration();
    const max_iterations = ConfigMod.maxAgentIterations();

    var messages = std.ArrayList(Models.Message){};
    defer {
        for (messages.items) |*msg| {
            Tools.freeConversationMessage(allocator, msg);
        }
        messages.deinit(allocator);
    }

    try messages.append(allocator, .{ .role = "user", .content = try allocator.dupe(u8, prompt) });

    try debugf(
        debug_enabled,
        "start agent run: max_iterations={d} max_tool_calls_per_step={d} prompt_len={d}",
        .{ max_iterations, max_tool_calls, prompt.len },
    );
    logSink(log_sink, "[agent] start prompt (len={d})\n", .{prompt.len});

    var iterations: u8 = 0;
    while (iterations < max_iterations) : (iterations += 1) {
        try debugf(debug_enabled, "iteration {d}: sending completion request with {d} messages", .{ iterations, messages.items.len });

        var request_used_streaming = false;
        const response_body = blk: {
            if (stream_sink) |sink| {
                request_used_streaming = true;
                const streaming = Llm.sendCompletionRequestStreaming(allocator, diag, config, messages.items, sink) catch |err| {
                    request_used_streaming = false;
                    switch (err) {
                        error.StreamingToolCallsUnsupported,
                        error.HttpError,
                        error.JsonError,
                        error.ApiError,
                        => {
                            logSink(log_sink, "[agent] streaming request failed ({s}), retrying without stream\n", .{@errorName(err)});
                            break :blk try Llm.sendCompletionRequest(
                                allocator,
                                diag,
                                config,
                                messages.items,
                            );
                        },
                        error.OutOfMemory => {
                            return error.OutOfMemory;
                        },
                        else => {
                            logSink(log_sink, "[agent] streaming request failed ({s}), retrying without stream\n", .{@errorName(err)});
                            break :blk try Llm.sendCompletionRequest(
                                allocator,
                                diag,
                                config,
                                messages.items,
                            );
                        },
                    }
                };
                break :blk streaming;
            }

            break :blk try Llm.sendCompletionRequest(allocator, diag, config, messages.items);
        };
        defer allocator.free(response_body);

        try debugf(debug_enabled, "iteration {d}: response bytes={d}", .{ iterations, response_body.len });

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch |err| {
            try diag.setf(.json, "Unable to decode provider JSON response (iteration {d}): {any}", .{ iterations, err });
            return error.JsonError;
        };
        defer parsed.deinit();

        const response_obj = try JsonUtils.asObject(diag, parsed.value, "response");
        try Llm.checkApiError(diag, response_obj);

        const choices = try JsonUtils.asArray(diag, try JsonUtils.field(diag, response_obj, "choices"), "response.choices");
        if (choices.items.len == 0) {
            diag.setBorrowed(.validation, "No choices were returned in API response");
            return error.NoChoices;
        }

        const first_choice = try JsonUtils.asObject(diag, choices.items[0], "response.choices[0]");
        const message_obj = try JsonUtils.asObject(diag, try JsonUtils.field(diag, first_choice, "message"), "response.choices[0].message");

        const assistant = Tools.parseAssistantMessage(allocator, diag, message_obj) catch |err| {
            try diag.setf(.json, "Failed to parse assistant message at iteration {d}: {any}", .{ iterations, err });
            return err;
        };

        if (assistant.tool_calls) |calls| {
            if (calls.len > max_tool_calls) {
                try diag.setf(
                    .validation,
                    "Too many tool calls in one response (got {d}, limit {d})",
                    .{ calls.len, max_tool_calls },
                );
                var assistant_to_cleanup = Models.Message{
                    .role = "assistant",
                    .content = assistant.content,
                    .tool_calls = assistant.tool_calls,
                    .tool_call_id = null,
                };
                Tools.freeConversationMessage(allocator, &assistant_to_cleanup);
                return error.TooManyToolCalls;
            }
        }

        const assistant_msg = Models.Message{
            .role = "assistant",
            .content = assistant.content,
            .tool_calls = assistant.tool_calls,
            .tool_call_id = null,
            .reasoning_content = assistant.reasoning_content,
        };

        messages.append(allocator, assistant_msg) catch |err| {
            Tools.freeConversationMessage(allocator, &assistant_msg);
            return err;
        };

        if (assistant.tool_calls == null or assistant.tool_calls.?.len == 0) {
            const final_content = assistant.content orelse {
                diag.setBorrowed(.validation, "Assistant final response does not include content");
                return error.MissingField;
            };
            if (output) |buffer| {
                if (request_used_streaming) {
                    if (buffer.items.len == 0) {
                        try buffer.appendSlice(allocator, final_content);
                    }
                } else {
                    try buffer.appendSlice(allocator, final_content);
                }
            } else {
                try Prompt.writeAll(diag, final_content);
            }
            logSink(log_sink, "[assistant] {s}\n", .{final_content});
            try debugf(debug_enabled, "iteration {d}: finished with final assistant content length {d}", .{ iterations, final_content.len });
            break;
        }

        const tool_calls = assistant.tool_calls.?;
        try debugf(debug_enabled, "iteration {d}: assistant requested {d} tool calls", .{ iterations, tool_calls.len });

        for (tool_calls, 0..) |call, call_index| {
            logSink(log_sink, "[tool] {s} id={s}\n", .{ call.function.name, call.id });
            const result = try Tools.executeToolCall(allocator, diag, call_index + 1, call);
            const tool_msg = Models.Message{
                .role = "tool",
                .tool_call_id = try allocator.dupe(u8, call.id),
                .content = result,
                .tool_calls = null,
            };
            messages.append(allocator, tool_msg) catch |err| {
                Tools.freeConversationMessage(allocator, &tool_msg);
                return err;
            };

            logSink(log_sink, "[tool] result bytes={d}\n", .{result.len});
            logSinkSnippet(log_sink, "[tool] output: ", result);
            try debugf(
                debug_enabled,
                "iteration {d}: appended tool result #{d} for id={s}, bytes={d}",
                .{ iterations, call_index + 1, call.id, result.len },
            );
        }
    } else {
        diag.setBorrowed(.validation, "Agent loop exceeded maximum iterations");
        return error.AgentLoopExceeded;
    }
}
