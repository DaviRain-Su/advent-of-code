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

pub fn runAgent(allocator: std.mem.Allocator, diag: *ErrorReport, config: ConfigMod.Config, prompt: []const u8, output: ?*std.ArrayList(u8)) !void {
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

    var iterations: u8 = 0;
    while (iterations < max_iterations) : (iterations += 1) {
        try debugf(debug_enabled, "iteration {d}: sending completion request with {d} messages", .{ iterations, messages.items.len });

        const response_body = Llm.sendCompletionRequest(allocator, diag, config, messages.items) catch |err| {
            switch (err) {
                error.HttpError => {
                    try diag.setf(.network, "Request failed at iteration {d}: HTTP request failed", .{iterations});
                    return error.HttpError;
                },
                else => {
                    diag.setf(.network, "Unexpected network error at iteration {d}: {any}", .{ iterations, err }) catch {};
                    return error.HttpError;
                },
            }
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
                try buffer.appendSlice(allocator, final_content);
            } else {
                try Prompt.writeAll(diag, final_content);
            }
            try debugf(debug_enabled, "iteration {d}: finished with final assistant content length {d}", .{ iterations, final_content.len });
            break;
        }

        const tool_calls = assistant.tool_calls.?;
        try debugf(debug_enabled, "iteration {d}: assistant requested {d} tool calls", .{ iterations, tool_calls.len });

        for (tool_calls, 0..) |call, call_index| {
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
