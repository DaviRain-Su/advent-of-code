const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig");
const Agent = @import("agent.zig");
const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const ConfigMod = @import("config.zig");
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

fn focusLabel(focus: FocusPanel) []const u8 {
    return switch (focus) {
        .input => "Input",
        .history => "History",
        .logs => "Logs",
    };
}

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

    var status_buf: [160]u8 = undefined;
    const status_line = std.fmt.bufPrint(&status_buf, "Model: {s}  Focus: {s}", .{ resolveModelLabel(), focusLabel(focus) }) catch "";

    try render(&vx, tty.writer(), .{
        .input = &input,
        .history_view = &history_view,
        .log_view = &log_view,
        .history_buffer = &history_buffer,
        .log_buffer = &log_buffer,
        .focus = focus,
        .theme = theme,
        .status_line = status_line,
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
                                try appendStyled(allocator, &history_buffer, theme.user, prompt);
                                try appendPlain(allocator, &history_buffer, "\n");
                                scrollToBottom(&history_view, &history_buffer);
                                try appendPlain(allocator, &log_buffer, "Running prompt...\n");
                                scrollToBottom(&log_view, &log_buffer);

                                var status_buf_running: [160]u8 = undefined;
                                const status_line_running = std.fmt.bufPrint(&status_buf_running, "Model: {s}  Focus: {s}  Status: running", .{ resolveModelLabel(), focusLabel(focus) }) catch "";

                                try render(&vx, tty.writer(), .{
                                    .input = &input,
                                    .history_view = &history_view,
                                    .log_view = &log_view,
                                    .history_buffer = &history_buffer,
                                    .log_buffer = &log_buffer,
                                    .focus = focus,
                                    .theme = theme,
                                    .status_line = status_line_running,
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
                                    try appendStyled(allocator, &history_buffer, theme.assistant, output.items);
                                    try appendPlain(allocator, &history_buffer, "\n");
                                    scrollToBottom(&history_view, &history_buffer);
                                }

                                try appendPlain(allocator, &log_buffer, "Done.\n");
                                scrollToBottom(&log_view, &log_buffer);
                                mode = .input;
                                focus = .input;
                            }
                        } else if (key.matches('c', .{ .ctrl = true })) {
                            diag.setBorrowed(.usage, "Prompt cancelled");
                            return error.UsageError;
                        } else {
                            try input.update(.{ .key_press = key });
                        }
                    },
                    .running => {},
                }
            },
        }

        var status_buf_loop: [160]u8 = undefined;
        const status_line_loop = std.fmt.bufPrint(&status_buf_loop, "Model: {s}  Focus: {s}", .{ resolveModelLabel(), focusLabel(focus) }) catch "";

        try render(&vx, tty.writer(), .{
            .input = &input,
            .history_view = &history_view,
            .log_view = &log_view,
            .history_buffer = &history_buffer,
            .log_buffer = &log_buffer,
            .focus = focus,
            .theme = theme,
            .status_line = status_line_loop,
        });
    }
}

const RenderState = struct {
    input: *TextInput,
    history_view: *TextView,
    log_view: *TextView,
    history_buffer: *TextView.Buffer,
    log_buffer: *TextView.Buffer,
    focus: FocusPanel,
    theme: Theme,
    status_line: []const u8,
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

    const status_segment = vaxis.Cell.Segment{ .text = state.status_line, .style = state.theme.status };
    _ = win.printSegment(status_segment, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

    const content_start: usize = 1;
    const content_height: usize = total_height - 2;
    const split_col: usize = total_width * 3 / 4;

    const history_panel = win.child(.{
        .x_off = 0,
        .y_off = @intCast(content_start),
        .width = @intCast(split_col),
        .height = @intCast(content_height),
    });

    drawPanel(
        history_panel,
        state.history_view,
        state.history_buffer,
        "History",
        state.theme,
    );

    const log_panel = win.child(.{
        .x_off = @intCast(split_col + 1),
        .y_off = @intCast(content_start),
        .width = @intCast(total_width - split_col - 1),
        .height = @intCast(content_height),
    });

    drawPanel(
        log_panel,
        state.log_view,
        state.log_buffer,
        "Logs",
        state.theme,
    );

    if (split_col < total_width) {
        const line_style = if (state.focus == .logs or state.focus == .history)
            state.theme.focus_border
        else
            state.theme.border;
        var row: usize = 0;
        while (row < content_height) : (row += 1) {
            win.writeCell(@intCast(split_col), @intCast(row + content_start), .{ .char = .{ .grapheme = "│", .width = 1 }, .style = line_style });
        }
    }

    const separator_row: usize = total_height - 2;
    var col: usize = 0;
    while (col < total_width) : (col += 1) {
        win.writeCell(@intCast(col), @intCast(separator_row), .{ .char = .{ .grapheme = "─", .width = 1 }, .style = state.theme.border });
    }

    const input_row: usize = total_height - 1;
    const input_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row), .width = @intCast(total_width), .height = 1 });
    input_win.fill(.{ .style = state.theme.bg });

    const label = vaxis.Cell.Segment{ .text = "Input> ", .style = state.theme.status };
    _ = input_win.printSegment(label, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });
    const label_len: u16 = 7;
    const input_child = input_win.child(.{ .x_off = @intCast(label_len), .y_off = 0, .width = @intCast(@max(total_width - label_len, 1)), .height = 1 });
    input_child.fill(.{ .style = state.theme.bg });
    state.input.draw(input_child);
    input_child.showCursor(state.input.prev_cursor_col, 0);

    try vx.render(tty_writer);
}

fn drawPanel(panel: vaxis.Window, view: *TextView, buffer: *TextView.Buffer, title: []const u8, theme: Theme) void {
    if (panel.width == 0 or panel.height == 0) return;

    panel.fill(.{ .style = theme.bg });

    const title_segment = vaxis.Cell.Segment{ .text = title, .style = theme.title };
    _ = panel.printSegment(title_segment, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });

    if (panel.height <= 1) return;
    const content_win = panel.child(.{
        .x_off = 0,
        .y_off = 1,
        .width = @intCast(panel.width),
        .height = @intCast(panel.height - 1),
    });

    content_win.fill(.{ .style = theme.bg });
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
