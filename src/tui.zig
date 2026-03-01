const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const App = @import("app.zig");
const Agent = @import("agent.zig");
const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const ConfigMod = @import("config.zig");
const Key = vaxis.Key;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

const UiMode = enum {
    input,
    running,
};

const Role = enum {
    user,
    assistant,
    system,
};

const Message = struct {
    role: Role,
    content: []const u8,
};

const Theme = struct {
    bg: vaxis.Style = .{ .fg = .default, .bg = .{ .index = 0 } },
    title_bar: vaxis.Style = .{ .fg = .{ .index = 0 }, .bg = .{ .index = 6 }, .bold = true },
    separator: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } },
    user: vaxis.Style = .{ .fg = .{ .index = 2 }, .bg = .{ .index = 0 }, .bold = true },
    assistant: vaxis.Style = .{ .fg = .{ .index = 4 }, .bg = .{ .index = 0 } },
    system: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } },
    input_prompt: vaxis.Style = .{ .fg = .{ .index = 3 }, .bg = .{ .index = 0 }, .bold = true },
    input_text: vaxis.Style = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
};

fn resolveModelLabel() []const u8 {
    if (std.posix.getenv("OPENROUTER_MODEL")) |model| {
        if (model.len > 0) return model;
    }

    const base_url = std.posix.getenv("OPENROUTER_BASE_URL") orelse ConfigMod.Defaults.default_base_url;
    if (std.mem.indexOf(u8, base_url, "deepseek") != null) {
        return ConfigMod.Defaults.default_deepseek_model;
    }

    return ConfigMod.Defaults.default_openai_model;
}

const TuiState = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    theme: Theme,
    input_buffer: std.ArrayList(u8),
    input_history: std.ArrayList([]const u8),
    history_index: ?usize,
    output: std.ArrayList(u8),
    mode: UiMode,
    crash_log: ?std.fs.File,

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
            .crash_log = null,
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

        if (self.crash_log) |file| {
            file.close();
        }
    }

    fn log(self: *const TuiState, comptime fmt: []const u8, args: anytype) void {
        if (self.crash_log) |file| {
            var mutable = file;
            logCrash(&mutable, fmt, args);
        }
    }
};

fn logCrash(file: *std.fs.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = file.write(line) catch {};
    _ = file.write("\n") catch {};
}

fn probeTTY() ?std.posix.E {
    const path = "/dev/tty" ++ [_]u8{0};
    const flags: std.posix.O = .{ .ACCMODE = .RDWR };

    while (true) {
        const fd = std.c.open(path, flags);
        if (fd >= 0) {
            std.posix.close(@intCast(fd));
            return null;
        }

        const err = std.posix.errno(fd);
        if (err == .INTR) continue;
        return err;
    }
}

pub fn run(allocator: std.mem.Allocator, diag: *ErrorReport) !void {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        diag.setBorrowed(.usage, "TUI requires a TTY. Use -p for CLI mode.");
        return error.TuiUnavailable;
    }

    var state = TuiState.init(allocator, .{});
    defer state.deinit();

    state.crash_log = std.fs.cwd().createFile("/tmp/claude_tui_crash.log", .{ .truncate = true }) catch null;
    errdefer |err| {
        state.log("tui error: {s}", .{@errorName(err)});
    }

    if (builtin.os.tag != .windows) {
        if (probeTTY()) |err| {
            state.log("tui preflight failed open /dev/tty: {s}", .{@tagName(err)});
            diag.setBorrowed(.usage, "TUI requires a controlling terminal (/dev/tty). Use -p for CLI mode.");
            return error.TuiUnavailable;
        }
    }

    var tty_buffer: [4096]u8 = undefined;
    var tty = vaxis.Tty.init(tty_buffer[0..]) catch |err| {
        state.log("Failed to initialize TUI: {s}", .{@errorName(err)});
        diag.setf(.usage, "Failed to initialize TUI: {any}", .{err}) catch {};
        return error.TuiUnavailable;
    };
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), std.time.ns_per_s);

    var loop = vaxis.Loop(Event){ .tty = &tty, .vaxis = &vx };
    try loop.init();
    defer loop.stop();
    try loop.start();

    var winsize: ?vaxis.Winsize = null;
    while (winsize == null) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            else => {},
        }
    }

    try appendMessage(allocator, &state.messages, .system, "Welcome to Claude Code TUI.");
    try appendMessage(allocator, &state.messages, .system, "Ready.");

    try render(&vx, tty.writer(), &state);

    const sink = Agent.LogSink{ .ctx = &state, .write = logSinkWrite };

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
                const should_continue = try handleKeyEvent(allocator, &vx, tty.writer(), &state, key, sink, diag);
                if (!should_continue) {
                    return error.UsageError;
                }
            },
        }

        render(&vx, tty.writer(), &state) catch |err| {
            state.log("render loop failed: {s}", .{@errorName(err)});
            diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
            return error.TuiUnavailable;
        };
    }
}

fn handleKeyEvent(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    state: *TuiState,
    key: Key,
    sink: Agent.LogSink,
    diag: *ErrorReport,
) !bool {
    if (state.mode == .running) {
        if (key.matches('c', .{ .ctrl = true })) {
            diag.setBorrowed(.usage, "Prompt cancelled");
            return false;
        }
        return true;
    }

    if (key.matches(Key.up, .{})) {
        try navigateHistoryUp(allocator, state);
    } else if (key.matches(Key.down, .{})) {
        try navigateHistoryDown(allocator, state);
    } else if (key.matches(Key.backspace, .{})) {
        _ = popUtf8Char(&state.input_buffer);
    } else if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
        try submitPrompt(allocator, vx, writer, state, diag, sink);
    } else if (key.matches('c', .{ .ctrl = true })) {
        diag.setBorrowed(.usage, "Prompt cancelled");
        return false;
    } else if (key.text) |text| {
        try state.input_buffer.appendSlice(allocator, text);
    }

    return true;
}

fn navigateHistoryUp(allocator: std.mem.Allocator, state: *TuiState) !void {
    if (state.input_history.items.len == 0) return;

    if (state.history_index == null) {
        state.history_index = state.input_history.items.len - 1;
    } else if (state.history_index.? > 0) {
        state.history_index = state.history_index.? - 1;
    }

    const idx = state.history_index.?;
    try setInputBuffer(allocator, &state.input_buffer, state.input_history.items[idx]);
}

fn navigateHistoryDown(allocator: std.mem.Allocator, state: *TuiState) !void {
    if (state.history_index) |idx| {
        if (idx + 1 < state.input_history.items.len) {
            state.history_index = idx + 1;
            try setInputBuffer(allocator, &state.input_buffer, state.input_history.items[state.history_index.?]);
        } else {
            state.history_index = null;
            state.input_buffer.clearRetainingCapacity();
        }
    }
}

fn submitPrompt(
    allocator: std.mem.Allocator,
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    state: *TuiState,
    diag: *ErrorReport,
    sink: Agent.LogSink,
) !void {
    if (state.input_buffer.items.len == 0) {
        try appendMessage(allocator, &state.messages, .system, "Prompt cannot be empty.");
        return;
    }

    const prompt = try allocator.dupe(u8, state.input_buffer.items);
    defer allocator.free(prompt);

    try state.input_history.append(allocator, try allocator.dupe(u8, prompt));
    state.history_index = null;

    state.input_buffer.clearRetainingCapacity();
    state.output.clearRetainingCapacity();
    state.mode = .running;

    try appendMessage(allocator, &state.messages, .user, prompt);
    try appendMessage(allocator, &state.messages, .system, "Running prompt...");

    render(&vx, writer, state) catch |err| {
        state.log("render before runWithPrompt failed: {s}", .{@errorName(err)});
        diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
        return error.TuiUnavailable;
    };

    state.log("runWithPrompt start len={d}", .{prompt.len});

    App.runWithPrompt(allocator, diag, prompt, &state.output, sink) catch |err| {
        state.output.clearRetainingCapacity();
        const msg = try allocator.dupe(u8, Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error");
        defer allocator.free(msg);
        state.log("runWithPrompt error: {s}", .{@errorName(err)});
        state.log("details: {s}", .{msg});
        try appendMessage(allocator, &state.messages, .system, msg);
        try state.output.appendSlice(allocator, msg);
    };

    state.log("runWithPrompt end len={d}", .{state.output.items.len});

    if (state.output.items.len > 0) {
        try appendMessage(allocator, &state.messages, .assistant, state.output.items);
    }

    try appendMessage(allocator, &state.messages, .system, "Done.");
    state.mode = .input;
}

fn render(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    state: *const TuiState,
) !void {
    const win = vx.window();
    win.fill(.{ .style = state.theme.bg });

    const height = win.height;
    const width = win.width;

    if (height < 6 or width < 20) {
        try vx.render(writer);
        return;
    }

    drawTitleBar(win, width, state.theme);

    const message_area_height: u16 = @intCast(height - 3);
    const max_content_width: usize = if (width > 2) @as(usize, width) - 2 else 0;
    const total_lines = totalMessageLines(state.messages.items, max_content_width);
    const max_display: usize = message_area_height;
    const lines_to_skip: usize = if (total_lines > max_display) total_lines - max_display else 0;

    renderMessages(
        win,
        state.messages.items,
        state.theme,
        max_content_width,
        message_area_height,
        lines_to_skip,
    );

    const sep_row: u16 = @intCast(height - 2);
    drawSeparator(win, width, sep_row, state.theme);

    const input_row: u16 = @intCast(height - 1);
    renderInputRow(win, width, input_row, state);

    try vx.render(writer);
    try writer.flush();
}

fn totalMessageLines(messages: []const Message, max_content_width: usize) usize {
    var total_lines: usize = 0;
    for (messages) |msg| {
        var iter = std.mem.splitScalar(u8, msg.content, '\n');
        while (iter.next()) |line| {
            total_lines += countWrappedLines(line, max_content_width);
        }
    }
    return total_lines;
}

fn renderMessages(
    win: vaxis.Window,
    messages: []const Message,
    theme: Theme,
    max_content_width: usize,
    message_area_height: u16,
    lines_to_skip: usize,
) void {
    var row: u16 = 1;
    var skipped: usize = 0;

    for (messages) |msg| {
        if (row >= message_area_height + 1) break;

        const prefix = rolePrefix(msg.role);
        const style = roleStyle(msg.role, theme);
        var first_wrapped_line = true;

        var line_iter = std.mem.splitScalar(u8, msg.content, '\n');
        while (line_iter.next()) |line| {
            var remaining = line;

            if (remaining.len == 0) {
                if (skipped < lines_to_skip) {
                    skipped += 1;
                    first_wrapped_line = false;
                } else if (row < message_area_height + 1) {
                    const prefix_text = if (first_wrapped_line) prefix else "  ";
                    renderMessageLine(win, row, prefix_text, style, "");
                    row += 1;
                }
                first_wrapped_line = false;
                continue;
            }

            while (remaining.len > 0) {
                const segment = if (displayWidth(remaining) > max_content_width)
                    headSliceByDisplayWidth(remaining, max_content_width)
                else
                    remaining;

                if (skipped < lines_to_skip) {
                    skipped += 1;
                } else if (row < message_area_height + 1) {
                    const prefix_text = if (first_wrapped_line) prefix else "  ";
                    renderMessageLine(win, row, prefix_text, style, segment);
                    row += 1;
                }

                first_wrapped_line = false;

                if (segment.len == remaining.len) break;
                remaining = remaining[segment.len..];
                if (segment.len == 0) break;
            }
        }
    }
}

fn renderMessageLine(
    win: vaxis.Window,
    row: u16,
    prefix: []const u8,
    style: vaxis.Style,
    content: []const u8,
) void {
    const prefix_seg = vaxis.Segment{ .text = prefix, .style = style };
    _ = win.print(&.{prefix_seg}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });

    if (content.len == 0) return;
    const content_seg = vaxis.Segment{ .text = content, .style = style };
    _ = win.print(&.{content_seg}, .{ .row_offset = row, .col_offset = 2, .wrap = .none });
}

fn renderInputRow(
    win: vaxis.Window,
    width: u16,
    input_row: u16,
    state: *const TuiState,
) void {
    const input_prefix = vaxis.Segment{ .text = "> ", .style = state.theme.input_prompt };
    _ = win.print(&.{input_prefix}, .{ .row_offset = input_row, .col_offset = 0, .wrap = .none });

    if (state.input_buffer.items.len > 0) {
        const max_width: usize = if (width > 2) @as(usize, width) - 2 else 0;
        const display = tailSliceByDisplayWidth(state.input_buffer.items, max_width);
        const input_seg = vaxis.Segment{ .text = display, .style = state.theme.input_text };
        _ = win.print(&.{input_seg}, .{ .row_offset = input_row, .col_offset = 2, .wrap = .none });
    }

    const display_len = displayWidth(state.input_buffer.items);
    const cursor_col: u16 = @intCast(@min(display_len + 2, width - 1));
    win.showCursor(cursor_col, input_row);
}

fn rolePrefix(role: Role) []const u8 {
    return switch (role) {
        .user => "> ",
        .assistant => "< ",
        .system => "  ",
    };
}

fn roleStyle(role: Role, theme: Theme) vaxis.Style {
    return switch (role) {
        .user => theme.user,
        .assistant => theme.assistant,
        .system => theme.system,
    };
}

fn drawTitleBar(win: vaxis.Window, width: u16, theme: Theme) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        win.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = theme.title_bar });
    }

    const title_text: []const u8 = " Claude Code ";
    const display_title = if (title_text.len > @as(usize, width)) title_text[0..@as(usize, width)] else title_text;
    const title_len: u16 = @intCast(display_title.len);
    const start_col: u16 = if (width > title_len) (width - title_len) / 2 else 0;
    const title_seg = vaxis.Segment{ .text = display_title, .style = theme.title_bar };
    _ = win.print(&.{title_seg}, .{ .row_offset = 0, .col_offset = start_col, .wrap = .none });
}

fn drawSeparator(win: vaxis.Window, width: u16, row: u16, theme: Theme) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = "-", .width = 1 }, .style = theme.separator });
    }
}

fn appendMessage(allocator: std.mem.Allocator, messages: *std.ArrayList(Message), role: Role, content: []const u8) !void {
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

fn displayWidth(bytes: []const u8) usize {
    var width: usize = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = bytes, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch 1;
        width +|= vaxis.gwidth.gwidth(buf[0..len], .unicode);
    }
    return width;
}

fn countWrappedLines(line: []const u8, max_width: usize) usize {
    if (max_width == 0) return 1;
    if (line.len == 0) return 1;

    var count: usize = 0;
    var remaining = line;
    while (remaining.len > 0) {
        const segment = if (displayWidth(remaining) > max_width)
            headSliceByDisplayWidth(remaining, max_width)
        else
            remaining;
        count += 1;
        if (segment.len == 0 or segment.len >= remaining.len) break;
        remaining = remaining[segment.len..];
    }

    return count;
}

fn tailSliceByDisplayWidth(bytes: []const u8, max_width: usize) []const u8 {
    if (displayWidth(bytes) <= max_width) return bytes;

    var width_from_end: usize = 0;
    var start: usize = bytes.len;

    while (start > 0) {
        var char_start = start - 1;
        while (char_start > 0 and (bytes[char_start] & 0xC0) == 0x80) {
            char_start -= 1;
        }

        const char_bytes = bytes[char_start..start];
        const char_width = vaxis.gwidth.gwidth(char_bytes, .unicode);
        if (width_from_end + char_width > max_width) break;

        width_from_end += char_width;
        start = char_start;
    }

    return bytes[start..];
}

fn headSliceByDisplayWidth(bytes: []const u8, max_width: usize) []const u8 {
    if (bytes.len == 0 or max_width == 0) return "";

    var i: usize = 0;
    var width: usize = 0;
    var end: usize = 0;

    while (i < bytes.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 1;
        const next_i = @min(i + cp_len, bytes.len);
        const char_bytes = bytes[i..next_i];
        const cp_width = vaxis.gwidth.gwidth(char_bytes, .unicode);

        if (width + cp_width > max_width) break;
        width += cp_width;
        end = next_i;
        i = next_i;
    }

    return bytes[0..end];
}

fn logSinkWrite(ctx: *anyopaque, msg: []const u8) void {
    const state: *TuiState = @ptrCast(@alignCast(ctx));
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        appendMessage(state.allocator, state.messages, .system, line) catch {};
    }
}
