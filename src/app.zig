const std = @import("std");

const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const ConfigMod = @import("config.zig");
const JsonUtils = @import("json_utils.zig").Json;
const Models = @import("models.zig");
const Prompt = @import("prompt.zig");
const Tools = @import("tools.zig");
const Llm = @import("llm.zig");

pub fn run(diag: *ErrorReport) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const prompt = Prompt.parsePrompt(allocator, diag) catch |err| {
        switch (err) {
            error.UsageError => return err,
            else => {
                diag.setBorrowed(.validation, "Unexpected error while reading command-line arguments");
                return error.UsageError;
            },
        }
    };
    defer allocator.free(prompt);

    const config = ConfigMod.loadConfig(diag) catch |err| {
        return err;
    };

    var messages = std.ArrayList(Models.Message){};
    defer {
        for (messages.items) |*msg| {
            Tools.freeConversationMessage(allocator, msg);
        }
        messages.deinit(allocator);
    }

    try messages.append(allocator, .{ .role = "user", .content = try allocator.dupe(u8, prompt) });

    var iterations: u8 = 0;
    while (iterations < ConfigMod.Defaults.max_agent_iterations) : (iterations += 1) {
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

        try messages.append(allocator, .{
            .role = "assistant",
            .content = assistant.content,
            .tool_calls = assistant.tool_calls,
        });

        if (assistant.tool_calls == null or assistant.tool_calls.?.len == 0) {
            if (assistant.content) |final_content| {
                try Prompt.writeAll(diag, final_content);
            } else {
                diag.setBorrowed(.validation, "Assistant final response does not include content");
                return error.MissingField;
            }
            break;
        }

        for (assistant.tool_calls.?, 0..) |call, call_index| {
            const result = try Tools.executeToolCall(allocator, diag, call_index + 1, call);
            try messages.append(allocator, .{
                .role = "tool",
                .tool_call_id = try allocator.dupe(u8, call.id),
                .content = result,
            });
        }
    } else {
        diag.setBorrowed(.validation, "Agent loop exceeded maximum iterations");
        return error.AgentLoopExceeded;
    }
}
