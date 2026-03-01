const std = @import("std");
const vaxis = @import("vaxis");

const Agent = @import("agent.zig");
const Errors = @import("errors.zig");
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
    mode: UiMode,

    fn init(allocator: std.mem.Allocator, theme: Theme) TuiState {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message){},
            .theme = theme,
            .input_buffer = std.ArrayList(u8){},
            .input_history = std.ArrayList([]const u8){},
            .history_index = null,
            .output = std.ArrayList(u8){},
            .mode = .input,
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

        self.output.deinit(self.allocator);
    }
};

pub const KeyAction = enum {
    none,
    submit,
    exit,
};

pub const TuiController = struct {
    state: TuiState,
    pending_prompt: ?[]const u8,
    crash_log: ?std.fs.File,

    pub fn init(allocator: std.mem.Allocator, theme: Theme) TuiController {
        return .{
            .state = TuiState.init(allocator, theme),
            .pending_prompt = null,
            .crash_log = null,
        };
    }

    pub fn deinit(self: *TuiController) void {
        if (self.pending_prompt) |prompt| {
            self.state.allocator.free(prompt);
        }

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

    pub fn handleKeyEvent(
        self: *TuiController,
        allocator: std.mem.Allocator,
        key: Key,
        diag: *ErrorReport,
    ) !KeyAction {
        if (self.state.mode == .running) {
            if (key.matches('c', .{ .ctrl = true })) {
                diag.setBorrowed(.usage, "Prompt cancelled");
                return .exit;
            }
            return .none;
        }

        if (key.matches(Key.up, .{})) {
            try self.navigateHistoryUp(allocator);
        } else if (key.matches(Key.down, .{})) {
            try self.navigateHistoryDown(allocator);
        } else if (key.matches(Key.backspace, .{})) {
            _ = popUtf8Char(&self.state.input_buffer);
        } else if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
            return self.submitPrompt(allocator);
        } else if (key.matches('c', .{ .ctrl = true })) {
            diag.setBorrowed(.usage, "Prompt cancelled");
            return .exit;
        } else if (key.text) |text| {
            try self.state.input_buffer.appendSlice(allocator, text);
        }

        return .none;
    }

    pub fn consumePendingPrompt(self: *TuiController) ?[]const u8 {
        const prompt = self.pending_prompt;
        self.pending_prompt = null;
        return prompt;
    }

    pub fn logSink(self: *TuiController) Agent.LogSink {
        return .{ .ctx = self, .write = logSinkWrite };
    }

    pub fn appendMessage(self: *TuiController, role: Role, content: []const u8) !void {
        try appendMessageInternal(self.state.allocator, &self.state.messages, role, content);
    }

    pub fn finishRun(self: *TuiController) !void {
        if (self.state.output.items.len > 0) {
            try self.appendMessage(.assistant, self.state.output.items);
        }

        try self.appendMessage(.system, "Done.");
        self.state.mode = .input;
    }

    fn submitPrompt(self: *TuiController, allocator: std.mem.Allocator) !KeyAction {
        if (self.state.input_buffer.items.len == 0) {
            try self.appendMessage(.system, "Prompt cannot be empty.");
            return .none;
        }

        const prompt = try self.state.allocator.dupe(u8, self.state.input_buffer.items);
        errdefer self.state.allocator.free(prompt);

        try self.state.input_history.append(allocator, try self.state.allocator.dupe(u8, prompt));
        try self.appendMessage(.user, prompt);
        try self.appendMessage(.system, "Running prompt...");

        self.state.output.clearRetainingCapacity();
        self.state.input_buffer.clearRetainingCapacity();
        self.state.history_index = null;
        self.state.mode = .running;
        self.pending_prompt = prompt;
        return .submit;
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

fn logCrash(file: *std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(line) catch {};
    _ = file.write("\n") catch {};
}
