const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig");
const Agent = @import("agent.zig");
const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const Key = vaxis.Key;
const TextInput = vaxis.widgets.TextInput;
const TextView = vaxis.widgets.TextView;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

const UiMode = enum {
    input,
    running,
    done,
};

const FocusPanel = enum {
    input,
    history,
    logs,
};

const Theme = struct {
    bg: vaxis.Style = .{ .fg = .{ .index = 15 }, .bg = .{ .index = 0 } },
    title: vaxis.Style = .{ .fg = .{ .index = 14 }, .bg = .{ .index = 0 }, .bold = true },
    status: vaxis.Style = .{ .fg = .{ .index = 10 }, .bg = .{ .index = 0 } },
    warning: vaxis.Style = .{ .fg = .{ .index = 11 }, .bg = .{ .index = 0 }, .bold = true },
    border: vaxis.Style = .{ .fg = .{ .index = 8 }, .bg = .{ .index = 0 } },
    focus_border: vaxis.Style = .{ .fg = .{ .index = 12 }, .bg = .{ .index = 0 }, .bold = true },
    user: vaxis.Style = .{ .fg = .{ .index = 11 }, .bg = .{ .index = 0 }, .bold = true },
    assistant: vaxis.Style = .{ .fg = .{ .index = 10 }, .bg = .{ .index = 0 } },
    tool: vaxis.Style = .{ .fg = .{ .index = 14 }, .bg = .{ .index = 0 } },
    error_style: vaxis.Style = .{ .fg = .{ .index = 9 }, .bg = .{ .index = 0 }, .bold = true },
};

const LogState = struct {
    allocator: std.mem.Allocator,
    buffer: *TextView.Buffer,
    view: *TextView,
    theme: Theme,
};

pub fn run(allocator: std.mem.Allocator, diag: *ErrorReport) !void {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        diag.setBorrowed(.usage, "TUI requires a TTY. Use -p for CLI mode.");
        return error.TuiUnavailable;
    }

    var tty_buffer: [4096]u8 = undefined;
    var tty = vaxis.Tty.init(tty_buffer[0..]) catch |err| {
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

    var input = TextInput.init(allocator);
    defer input.deinit();

    var input_history = std.ArrayList([]const u8){};
    defer {
        for (input_history.items) |item| allocator.free(item);
        input_history.deinit(allocator);
    }
    var history_index: ?usize = null;

    var history_buffer = TextView.Buffer{};
    defer history_buffer.deinit(allocator);

    var log_buffer = TextView.Buffer{};
    defer log_buffer.deinit(allocator);

    var history_view = TextView{};
    var log_view = TextView{};

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    const theme: Theme = .{};
    var mode: UiMode = .input;
    var focus: FocusPanel = .input;

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

    try appendPlain(allocator, &history_buffer, "Welcome to Claude Code TUI.\n");
    try appendPlain(allocator, &log_buffer, "Ready.\n");

    try render(&vx, tty.writer(), .{
        .input = &input,
        .history_view = &history_view,
        .log_view = &log_view,
        .history_buffer = &history_buffer,
        .log_buffer = &log_buffer,
        .mode = mode,
        .focus = focus,
        .theme = theme,
    });

    var log_state = LogState{ .allocator = allocator, .buffer = &log_buffer, .view = &log_view, .theme = theme };
    const sink = Agent.LogSink{ .ctx = &log_state, .write = logSinkWrite };

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
                if (key.matches(Key.tab, .{})) {
                    focus = switch (focus) {
                        .input => .history,
                        .history => .logs,
                        .logs => .input,
                    };
                    break;
                }
                if (key.matches(Key.tab, .{ .shift = true })) {
                    focus = switch (focus) {
                        .input => .logs,
                        .history => .input,
                        .logs => .history,
                    };
                    break;
                }

                if (handleScrollKey(key, focus, &history_view, &log_view)) {
                    break;
                }

                switch (mode) {
                    .input => {
                        if (focus != .input) break;
                        if (key.matches(Key.up, .{})) {
                            if (input_history.items.len > 0) {
                                if (history_index == null) {
                                    history_index = input_history.items.len - 1;
                                } else if (history_index.? > 0) {
                                    history_index = history_index.? - 1;
                                }
                                const idx = history_index.?;
                                try setInputText(&input, input_history.items[idx]);
                            }
                        } else if (key.matches(Key.down, .{})) {
                            if (history_index) |idx| {
                                if (idx + 1 < input_history.items.len) {
                                    history_index = idx + 1;
                                    try setInputText(&input, input_history.items[history_index.?]);
                                } else {
                                    history_index = null;
                                    input.buf.clearRetainingCapacity();
                                }
                            }
                        } else if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                            if (input.buf.realLength() == 0) {
                                try appendStyled(allocator, &log_buffer, theme.warning, "Prompt cannot be empty.\n");
                                scrollToBottom(&log_view, &log_buffer);
                            } else {
                                const prompt = input.buf.toOwnedSlice() catch |err| {
                                    diag.setf(.validation, "Failed to capture prompt: {any}", .{err}) catch {};
                                    return error.UsageError;
                                };
                                defer allocator.free(prompt);

                                try input_history.append(allocator, try allocator.dupe(u8, prompt));
                                history_index = null;

                                input.buf.clearRetainingCapacity();
                                output.clearRetainingCapacity();
                                mode = .running;

                                try appendStyled(allocator, &history_buffer, theme.user, "User: ");
                                try appendPlain(allocator, &history_buffer, prompt);
                                try appendPlain(allocator, &history_buffer, "\n");
                                scrollToBottom(&history_view, &history_buffer);
                                try appendPlain(allocator, &log_buffer, "Running prompt...\n");
                                scrollToBottom(&log_view, &log_buffer);

                                try render(&vx, tty.writer(), .{
                                    .input = &input,
                                    .history_view = &history_view,
                                    .log_view = &log_view,
                                    .history_buffer = &history_buffer,
                                    .log_buffer = &log_buffer,
                                    .mode = mode,
                                    .focus = focus,
                                    .theme = theme,
                                });

                                App.runWithPrompt(allocator, diag, prompt, &output, sink) catch |err| {
                                    output.clearRetainingCapacity();
                                    const msg = Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error";
                                    defer allocator.free(msg);
                                    try appendStyled(allocator, &log_buffer, theme.error_style, "Error: ");
                                    try appendPlain(allocator, &log_buffer, msg);
                                    try appendPlain(allocator, &log_buffer, "\n");
                                    try output.appendSlice(allocator, msg);
                                    scrollToBottom(&log_view, &log_buffer);
                                };

                                if (output.items.len > 0) {
                                    try appendStyled(allocator, &history_buffer, theme.assistant, "Assistant: ");
                                    try appendPlain(allocator, &history_buffer, output.items);
                                    try appendPlain(allocator, &history_buffer, "\n");
                                    scrollToBottom(&history_view, &history_buffer);
                                }

                                try appendPlain(allocator, &log_buffer, "Done.\n");
                                scrollToBottom(&log_view, &log_buffer);
                                mode = .done;
                            }
                        } else if (key.matches('c', .{ .ctrl = true })) {
                            diag.setBorrowed(.usage, "Prompt cancelled");
                            return error.UsageError;
                        } else {
                            try input.update(.{ .key_press = key });
                        }
                    },
                    .running => {},
                    .done => {
                        if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                            mode = .input;
                        } else if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) {
                            return;
                        }
                    },
                }
            },
        }

        try render(&vx, tty.writer(), .{
            .input = &input,
            .history_view = &history_view,
            .log_view = &log_view,
            .history_buffer = &history_buffer,
            .log_buffer = &log_buffer,
            .mode = mode,
            .focus = focus,
            .theme = theme,
        });
    }
}

const RenderState = struct {
    input: *TextInput,
    history_view: *TextView,
    log_view: *TextView,
    history_buffer: *TextView.Buffer,
    log_buffer: *TextView.Buffer,
    mode: UiMode,
    focus: FocusPanel,
    theme: Theme,
};

fn render(vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, state: RenderState) !void {
    const win = vx.window();
    win.fill(.{ .style = state.theme.bg });

    const total_height: usize = win.height;
    const total_width: usize = win.width;
    if (total_height < 2 or total_width < 10) {
        try vx.render(tty_writer);
        return;
    }

    const content_start: usize = 0;
    const content_height: usize = total_height - 1;
    const split_col: usize = total_width * 3 / 4;

    const history_panel = win.child(.{
        .x_off = 0,
        .y_off = @intCast(content_start),
        .width = @intCast(split_col),
        .height = @intCast(content_height),
        .border = .{
            .where = .all,
            .style = if (state.focus == .history) state.theme.focus_border else state.theme.border,
        },
    });

    drawPanel(
        history_panel,
        state.history_view,
        state.history_buffer,
        "History",
        state.theme,
    );

    const log_panel = win.child(.{
        .x_off = @intCast(split_col),
        .y_off = @intCast(content_start),
        .width = @intCast(total_width - split_col),
        .height = @intCast(content_height),
        .border = .{
            .where = .all,
            .style = if (state.focus == .logs) state.theme.focus_border else state.theme.border,
        },
    });

    drawPanel(
        log_panel,
        state.log_view,
        state.log_buffer,
        "Logs",
        state.theme,
    );

    const input_row: usize = total_height - 1;
    const input_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row), .width = @intCast(total_width), .height = 1 });
    input_win.clear();

    if (state.mode == .input) {
        const label = vaxis.Cell.Segment{ .text = "Input> ", .style = state.theme.status };
        _ = input_win.printSegment(label, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
        const label_len: u16 = 7;
        const input_child = input_win.child(.{ .x_off = @intCast(label_len), .y_off = 0, .width = @intCast(@max(total_width - label_len, 1)), .height = 1 });
        input_child.clear();
        state.input.draw(input_child);
        input_child.showCursor(state.input.prev_cursor_col, 0);
    } else {
        input_win.hideCursor();
    }

    try vx.render(tty_writer);
}

fn drawPanel(panel: vaxis.Window, view: *TextView, buffer: *TextView.Buffer, title: []const u8, theme: Theme) void {
    if (panel.width <= 2 or panel.height <= 2) return;

    const inner = panel.child(.{
        .x_off = 1,
        .y_off = 1,
        .width = @intCast(panel.width - 2),
        .height = @intCast(panel.height - 2),
    });

    inner.fill(.{ .style = theme.bg });

    if (inner.height == 0) return;

    const title_segment = vaxis.Cell.Segment{ .text = title, .style = theme.title };
    _ = inner.printSegment(title_segment, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    if (inner.height <= 1) return;
    const content_win = inner.child(.{
        .x_off = 0,
        .y_off = 1,
        .width = @intCast(inner.width),
        .height = @intCast(inner.height - 1),
    });

    view.draw(content_win, buffer.*);
}

fn handleScrollKey(key: Key, focus: FocusPanel, history_view: *TextView, log_view: *TextView) bool {
    const is_scroll = key.matches(Key.page_up, .{}) or
        key.matches(Key.page_down, .{}) or
        key.matches(Key.home, .{}) or
        key.matches(Key.end, .{}) or
        key.matches(Key.up, .{}) or
        key.matches(Key.down, .{}) or
        key.matches(Key.up, .{ .ctrl = true }) or
        key.matches(Key.down, .{ .ctrl = true });

    if (!is_scroll) return false;

    if (focus == .history) {
        history_view.input(key);
        return true;
    }
    if (focus == .logs) {
        log_view.input(key);
        return true;
    }

    return false;
}

fn appendPlain(allocator: std.mem.Allocator, buffer: *TextView.Buffer, text: []const u8) !void {
    try buffer.append(allocator, .{ .bytes = text });
}

fn appendStyled(allocator: std.mem.Allocator, buffer: *TextView.Buffer, style: vaxis.Style, text: []const u8) !void {
    const start = buffer.content.items.len;
    try buffer.append(allocator, .{ .bytes = text });
    const end = buffer.content.items.len;
    try buffer.updateStyle(allocator, .{ .begin = start, .end = end, .style = style });
}

fn scrollToBottom(view: *TextView, buffer: *TextView.Buffer) void {
    view.scroll_view.scroll.y = buffer.rows;
}

fn setInputText(input: *TextInput, text: []const u8) !void {
    input.buf.clearRetainingCapacity();
    if (text.len == 0) return;
    try input.insertSliceAtCursor(text);
}

fn logSinkWrite(ctx: *anyopaque, msg: []const u8) void {
    const state: *LogState = @ptrCast(@alignCast(ctx));
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const style = if (std.mem.startsWith(u8, line, "[tool]"))
            state.theme.tool
        else if (std.mem.startsWith(u8, line, "[assistant]"))
            state.theme.assistant
        else if (std.mem.startsWith(u8, line, "[agent]"))
            state.theme.status
        else
            state.theme.status;
        appendStyled(state.allocator, state.buffer, style, line) catch {};
        appendPlain(state.allocator, state.buffer, "\n") catch {};
    }
    scrollToBottom(state.view, state.buffer);
}
