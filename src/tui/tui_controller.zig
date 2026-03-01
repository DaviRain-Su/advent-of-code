const std = @import("std");
const vaxis = @import("vaxis");

const Agent = @import("../agent.zig");
const Errors = @import("../errors.zig");
const ErrorReport = Errors.ErrorReport;
const Key = vaxis.Key;

pub const Theme = struct {
    bg: vaxis.Style = .{ .fg = .default, .bg = .{ .index = 0 } },
    title_bar: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true },
    separator: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } },
    user: vaxis.Style = .{ .fg = .{ .index = 2 }, .bg = .{ .index = 0 }, .bold = true },
    assistant: vaxis.Style = .{ .fg = .{ .index = 4 }, .bg = .{ .index = 0 } },
    system: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } },
    input_prompt: vaxis.Style = .{ .fg = .{ .index = 3 }, .bg = .{ .index = 0 }, .bold = true },
    input_text: vaxis.Style = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
};

pub const UiMode = enum {
    input,
    running,
};

pub const Role = enum {
    user,
    assistant,
    system,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const TuiState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    theme: Theme,
    input_buffer: std.ArrayList(u8),
    input_history: std.ArrayList([]const u8),
    history_index: ?usize,
    output: std.ArrayList(u8),
    pending_prompt: ?[]const u8,
    mode: UiMode,
    suppress_empty_submit: bool,
    run_in_progress: bool,
    active_run_id: u64,

    fn init(allocator: std.mem.Allocator, theme: Theme) TuiState {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message){},
            .theme = theme,
            .input_buffer = std.ArrayList(u8){},
            .input_history = std.ArrayList([]const u8){},
            .history_index = null,
            .output = std.ArrayList(u8){},
            .pending_prompt = null,
            .mode = .input,
            .suppress_empty_submit = false,
            .run_in_progress = false,
            .active_run_id = 0,
        };
    }

    fn deinit(self: *TuiState) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);

        self.input_buffer.deinit(self.allocator);

        for (self.input_history.items) |item| {
            self.allocator.free(item);
        }
        self.input_history.deinit(self.allocator);

        if (self.pending_prompt) |prompt| {
            self.allocator.free(prompt);
        }

        self.output.deinit(self.allocator);
    }
};

pub const PromptRunner = *const fn (
    std.mem.Allocator,
    *ErrorReport,
    []const u8,
    ?*std.ArrayList(u8),
    ?Agent.LogSink,
    ?Agent.StreamSink,
) anyerror!void;

pub const Command = union(enum) {
    none,
    submit_prompt: []const u8,
    exit,
};

pub const ControllerAction = enum {
    none,
    request_exit,
};

pub const TuiController = struct {
    state: TuiState,
    prompt_runner: PromptRunner,
    crash_log: ?std.fs.File,

    pub fn init(
        allocator: std.mem.Allocator,
        theme: Theme,
        prompt_runner: PromptRunner,
    ) TuiController {
        return .{
            .state = TuiState.init(allocator, theme),
            .prompt_runner = prompt_runner,
            .crash_log = null,
        };
    }

    pub fn deinit(self: *TuiController) void {
        self.state.deinit();

        if (self.crash_log) |file| {
            file.close();
        }
    }

    pub fn setCrashLog(self: *TuiController, file: std.fs.File) void {
        self.crash_log = file;
    }

    pub fn log(self: *const TuiController, comptime fmt: []const u8, args: anytype) void {
        if (self.crash_log) |file| {
            var mutable = file;
            logCrash(&mutable, fmt, args);
        }
    }

    pub fn appendStartupMessages(self: *TuiController) !void {
        try self.appendMessage(.system, "Welcome to Claude Code TUI.");
        try self.appendMessage(.system, "Ready.");
    }

    pub fn takePendingPrompt(self: *TuiController) ?[]const u8 {
        const prompt = self.state.pending_prompt;
        self.state.pending_prompt = null;
        return prompt;
    }

    pub fn beginRun(self: *TuiController) u64 {
        self.state.run_in_progress = true;
        self.state.active_run_id +%= 1;
        self.state.mode = .running;
        return self.state.active_run_id;
    }

    pub fn finishRun(self: *TuiController) void {
        self.state.mode = .input;
        self.state.run_in_progress = false;
        self.state.suppress_empty_submit = false;
    }

    pub fn isCurrentRun(self: *const TuiController, run_id: u64) bool {
        return self.state.run_in_progress and self.state.active_run_id == run_id;
    }

    pub fn appendOutputChunk(self: *TuiController, chunk: []const u8) !void {
        try self.state.output.appendSlice(self.state.allocator, chunk);
    }

    pub fn handleKeyEvent(
        self: *TuiController,
        allocator: std.mem.Allocator,
        key: Key,
        diag: *ErrorReport,
    ) !Command {
        if (self.state.mode == .running) {
        if (key.matches('c', .{ .ctrl = true })) {
            diag.setBorrowed(.usage, "Prompt cancelled");
            return .exit;
        }
        return Command.none;
    }

    if (key.matches(Key.up, .{})) {
        self.state.suppress_empty_submit = false;
        try self.navigateHistoryUp(allocator);
    } else if (key.matches(Key.down, .{})) {
        self.state.suppress_empty_submit = false;
        try self.navigateHistoryDown(allocator);
    } else if (key.matches(Key.backspace, .{})) {
        self.state.suppress_empty_submit = false;
        _ = popUtf8Char(&self.state.input_buffer);
    } else if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
        return self.submitPrompt(allocator);
    } else if (key.matches('c', .{ .ctrl = true })) {
        diag.setBorrowed(.usage, "Prompt cancelled");
        return .exit;
    } else if (key.text) |text| {
        self.state.suppress_empty_submit = false;
        try self.state.input_buffer.appendSlice(allocator, text);
    }

        return Command.none;
    }

    pub fn handleEvent(
        self: *TuiController,
        allocator: std.mem.Allocator,
        key: Key,
        diag: *ErrorReport,
    ) !ControllerAction {
        const cmd = try self.handleKeyEvent(allocator, key, diag);
        try self.executeCommand(allocator, cmd);

        return switch (cmd) {
            .exit => .request_exit,
            else => .none,
        };
    }

    pub fn logSink(self: *TuiController) Agent.LogSink {
        return .{ .ctx = self, .write = logSinkWrite };
    }

    pub fn streamSink(self: *TuiController) Agent.StreamSink {
        return .{ .ctx = self, .write = streamSinkWrite };
    }

    pub fn appendMessage(self: *TuiController, role: Role, content: []const u8) !void {
        try appendMessageInternal(self.state.allocator, &self.state.messages, role, content);
    }

    pub fn executeCommand(self: *TuiController, allocator: std.mem.Allocator, cmd: Command) !void {
        switch (cmd) {
            .none => {},
            .exit => {},
            .submit_prompt => |prompt| {
                if (self.state.pending_prompt) |old| {
                    allocator.free(old);
                }

                self.state.pending_prompt = try allocator.dupe(u8, prompt);
            },
        }
    }

    pub fn hasPendingPrompt(self: *const TuiController) bool {
        return self.state.pending_prompt != null;
    }

    pub fn runPendingPrompt(self: *TuiController, allocator: std.mem.Allocator, diag: *ErrorReport) !void {
        const prompt = self.state.pending_prompt orelse return;
        self.state.pending_prompt = null;
        defer allocator.free(prompt);

        var run_error: ?[]const u8 = null;
        self.log("runWithPrompt start len={d}", .{prompt.len});

        self.prompt_runner(
            allocator,
            diag,
            prompt,
            &self.state.output,
            self.logSink(),
            self.streamSink(),
        ) catch |err| {
            self.state.output.clearRetainingCapacity();
            const msg = try allocator.dupe(u8, Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error");
            self.log("runWithPrompt error: {s}", .{@errorName(err)});
            self.log("details: {s}", .{msg});
            try self.appendMessage(.system, msg);
            try self.state.output.appendSlice(allocator, msg);
            run_error = msg;
        };

        self.log("runWithPrompt end len={d}", .{self.state.output.items.len});
        if (self.state.output.items.len > 0) {
            try self.appendMessage(.assistant, self.state.output.items);
        }

        try self.appendMessage(.system, "Done.");
        self.state.suppress_empty_submit = false;
        self.state.mode = .input;

        if (run_error) |msg| {
            allocator.free(msg);
        }
    }

    fn submitPrompt(self: *TuiController, allocator: std.mem.Allocator) !Command {
        if (self.state.input_buffer.items.len == 0) {
            if (self.state.suppress_empty_submit) {
                self.state.suppress_empty_submit = false;
                return .none;
            }

            try self.appendMessage(.system, "Prompt cannot be empty.");
            return .none;
        }
        self.state.suppress_empty_submit = false;

        const prompt = try self.state.allocator.dupe(u8, self.state.input_buffer.items);
        errdefer self.state.allocator.free(prompt);

        try self.state.input_history.append(allocator, try self.state.allocator.dupe(u8, prompt));
        try self.appendMessage(.user, prompt);
        try self.appendMessage(.system, "Running prompt...");

        self.state.output.clearRetainingCapacity();
        self.state.input_buffer.clearRetainingCapacity();
        self.state.history_index = null;
        self.state.mode = .running;
        self.state.suppress_empty_submit = true;
        return .{ .submit_prompt = prompt };
    }

    fn navigateHistoryUp(self: *TuiController, allocator: std.mem.Allocator) !void {
        if (self.state.input_history.items.len == 0) return;

        if (self.state.history_index == null) {
            self.state.history_index = self.state.input_history.items.len - 1;
        } else if (self.state.history_index.? > 0) {
            self.state.history_index = self.state.history_index.? - 1;
        }

        const idx = self.state.history_index.?;
        try setInputBuffer(allocator, &self.state.input_buffer, self.state.input_history.items[idx]);
    }

    fn navigateHistoryDown(self: *TuiController, allocator: std.mem.Allocator) !void {
        if (self.state.history_index) |idx| {
            if (idx + 1 < self.state.input_history.items.len) {
                self.state.history_index = idx + 1;
                try setInputBuffer(allocator, &self.state.input_buffer, self.state.input_history.items[self.state.history_index.?]);
            } else {
                self.state.history_index = null;
                self.state.input_buffer.clearRetainingCapacity();
            }
        }
    }
};

fn appendMessageInternal(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), role: Role, content: []const u8) !void {
    try messages.append(allocator, .{ .role = role, .content = try allocator.dupe(u8, content) });
}

fn setInputBuffer(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), text: []const u8) !void {
    buffer.clearRetainingCapacity();
    if (text.len == 0) return;
    try buffer.appendSlice(allocator, text);
}

fn popUtf8Char(buffer: *std.ArrayList(u8)) usize {
    if (buffer.items.len == 0) return 0;

    var index = buffer.items.len - 1;
    while (index > 0 and (buffer.items[index] & 0xC0) == 0x80) {
        index -= 1;
    }

    const removed = buffer.items.len - index;
    buffer.shrinkRetainingCapacity(index);
    return removed;
}

fn logSinkWrite(ctx: *anyopaque, msg: []const u8) void {
    const controller: *TuiController = @ptrCast(@alignCast(ctx));
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        appendMessageInternal(controller.state.allocator, &controller.state.messages, .system, line) catch {};
    }
}

fn streamSinkWrite(ctx: *anyopaque, chunk: []const u8) anyerror!void {
    if (chunk.len == 0) return;

    const controller: *TuiController = @ptrCast(@alignCast(ctx));
    try controller.state.output.appendSlice(controller.state.allocator, chunk);
}

fn logCrash(file: *std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(line) catch {};
    _ = file.write("\n") catch {};
}
