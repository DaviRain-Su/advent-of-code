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
    var focus: FocusPanel = .history;
    var show_empty_warning = false;

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
        .show_empty_warning = show_empty_warning,
        .theme = theme,
    });

    var log_state = LogState{ .allocator = allocator, .buffer = &log_buffer };
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
                    focus = if (focus == .history) .logs else .history;
                    break;
                }

                if (handleScrollKey(key, focus, &history_view, &log_view)) {
                    break;
                }

                switch (mode) {
                    .input => {
                        if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                            if (input.buf.realLength() == 0) {
                                show_empty_warning = true;
                            } else {
                                show_empty_warning = false;
                                const prompt = input.buf.toOwnedSlice() catch |err| {
                                    diag.setf(.validation, "Failed to capture prompt: {any}", .{err}) catch {};
                                    return error.UsageError;
                                };
                                defer allocator.free(prompt);

                                input.buf.clearRetainingCapacity();
                                output.clearRetainingCapacity();
                                mode = .running;

                                try appendStyled(allocator, &history_buffer, theme.user, "User: ");
                                try appendPlain(allocator, &history_buffer, prompt);
                                try appendPlain(allocator, &history_buffer, "\n");
                                try appendPlain(allocator, &log_buffer, "Running prompt...\n");

                                try render(&vx, tty.writer(), .{
                                    .input = &input,
                                    .history_view = &history_view,
                                    .log_view = &log_view,
                                    .history_buffer = &history_buffer,
                                    .log_buffer = &log_buffer,
                                    .mode = mode,
                                    .focus = focus,
                                    .show_empty_warning = show_empty_warning,
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
                                };

                                if (output.items.len > 0) {
                                    try appendStyled(allocator, &history_buffer, theme.assistant, "Assistant: ");
                                    try appendPlain(allocator, &history_buffer, output.items);
                                    try appendPlain(allocator, &history_buffer, "\n");
                                }

                                try appendPlain(allocator, &log_buffer, "Done.\n");
                                mode = .done;
                            }
                        } else if (key.matches('c', .{ .ctrl = true })) {
                            diag.setBorrowed(.usage, "Prompt cancelled");
                            return error.UsageError;
                        } else {
                            try input.update(.{ .key_press = key });
                            show_empty_warning = false;
                        }
                    },
                    .running => {},
                    .done => {
                        if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                            mode = .input;
                            show_empty_warning = false;
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
            .show_empty_warning = show_empty_warning,
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
    show_empty_warning: bool,
    theme: Theme,
};

fn render(vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, state: RenderState) !void {
    const win = vx.window();
    win.fill(.{ .style = state.theme.bg });

    const title_segment = vaxis.Cell.Segment{ .text = "Claude Code TUI", .style = state.theme.title };
    _ = win.printSegment(title_segment, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    const help_text = switch (state.mode) {
        .input => "Enter prompt and press Enter. Ctrl+C to cancel. Tab switches panel.",
        .running => "Running...",
        .done => "Press Enter for a new prompt. Press q to quit. Tab switches panel.",
    };
    const help_segment = vaxis.Cell.Segment{ .text = help_text, .style = state.theme.status };
    _ = win.printSegment(help_segment, .{ .row_offset = 1, .col_offset = 0, .wrap = .none });

    if (state.show_empty_warning and win.height > 2) {
        const warning = vaxis.Cell.Segment{ .text = "Prompt cannot be empty.", .style = state.theme.warning };
        _ = win.printSegment(warning, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    }

    const total_height: usize = win.height;
    const total_width: usize = win.width;
    if (total_height < 6 or total_width < 10) {
        try vx.render(tty_writer);
        return;
    }

    const content_start: usize = 3;
    const content_height: usize = total_height - 5;
    const history_height: usize = content_height * 2 / 3;
    _ = history_height;
    const split_col: usize = total_width * 2 / 3;

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
        state.input.draw(input_win);
        input_win.showCursor(state.input.prev_cursor_col, 0);
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
    if (key.matches(Key.page_up, .{}) or
        key.matches(Key.page_down, .{}) or
        key.matches(Key.home, .{}) or
        key.matches(Key.end, .{}) or
        key.matches(Key.up, .{ .ctrl = true }) or
        key.matches(Key.down, .{ .ctrl = true }))
    {
        if (focus == .history) {
            history_view.input(key);
        } else {
            log_view.input(key);
        }
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

fn logSinkWrite(ctx: *anyopaque, msg: []const u8) void {
    const state: *LogState = @ptrCast(@alignCast(ctx));
    appendPlain(state.allocator, state.buffer, msg) catch {};
}
