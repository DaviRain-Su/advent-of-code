const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const App = @import("app.zig");
const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const Controller = @import("tui_controller.zig");

const Key = vaxis.Key;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

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

    var controller = Controller.TuiController.init(allocator, .{});
    defer controller.deinit();

    if (std.fs.cwd().createFile("/tmp/claude_tui_crash.log", .{ .truncate = true })) |file| {
        controller.setCrashLog(file);
    } else |_| {
        // optional debug log, best-effort only
    }

    errdefer |err| {
        controller.log("tui error: {s}", .{@errorName(err)});
    }

    if (builtin.os.tag != .windows) {
        if (probeTTY()) |err| {
            controller.log("tui preflight failed open /dev/tty: {s}", .{@tagName(err)});
            diag.setBorrowed(.usage, "TUI requires a controlling terminal (/dev/tty). Use -p for CLI mode.");
            return error.TuiUnavailable;
        }
    }

    var tty_buffer: [4096]u8 = undefined;
    var tty = vaxis.Tty.init(tty_buffer[0..]) catch |err| {
        controller.log("Failed to initialize TUI: {s}", .{@errorName(err)});
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

    try controller.appendStartupMessages();
    try render(&vx, tty.writer(), &controller.state);

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
                const action = try controller.handleKeyEvent(allocator, key, diag);
                switch (action) {
                    .exit => {
                        return error.UsageError;
                    },
                    .submit => if (controller.consumePendingPrompt()) |prompt| {
                        defer allocator.free(prompt);
                        try executePrompt(allocator, diag, &controller, &vx, tty.writer(), prompt);
                    },
                    .none => {},
                }
            },
        }

        render(&vx, tty.writer(), &controller.state) catch |err| {
            controller.log("render loop failed: {s}", .{@errorName(err)});
            diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
            return error.TuiUnavailable;
        };
    }
}

fn executePrompt(
    allocator: std.mem.Allocator,
    diag: *ErrorReport,
    controller: *Controller.TuiController,
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    prompt: []const u8,
) !void {
    render(vx, writer, &controller.state) catch |err| {
        controller.log("render before runWithPrompt failed: {s}", .{@errorName(err)});
        diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
        return error.TuiUnavailable;
    };

    var run_error: ?[]const u8 = null;
    controller.log("runWithPrompt start len={d}", .{prompt.len});

    App.runWithPrompt(allocator, diag, prompt, &controller.state.output, controller.logSink()) catch |err| {
        controller.state.output.clearRetainingCapacity();
        const msg = try allocator.dupe(u8, Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error");
        controller.log("runWithPrompt error: {s}", .{@errorName(err)});
        controller.log("details: {s}", .{msg});
        try controller.appendMessage(.system, msg);
        try controller.state.output.appendSlice(allocator, msg);
        run_error = msg;
    };

    controller.log("runWithPrompt end len={d}", .{controller.state.output.items.len});
    try controller.finishRun();

    if (run_error) |msg| {
        allocator.free(msg);
    }
}

fn render(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    state: *const Controller.TuiState,
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

fn totalMessageLines(messages: []const Controller.Message, max_content_width: usize) usize {
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
    messages: []const Controller.Message,
    theme: Controller.Theme,
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
    state: *const Controller.TuiState,
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

fn rolePrefix(role: Controller.Role) []const u8 {
    return switch (role) {
        .user => "> ",
        .assistant => "< ",
        .system => "  ",
    };
}

fn roleStyle(role: Controller.Role, theme: Controller.Theme) vaxis.Style {
    return switch (role) {
        .user => theme.user,
        .assistant => theme.assistant,
        .system => theme.system,
    };
}

fn drawTitleBar(win: vaxis.Window, width: u16, theme: Controller.Theme) void {
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

fn drawSeparator(win: vaxis.Window, width: u16, row: u16, theme: Controller.Theme) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = "-", .width = 1 }, .style = theme.separator });
    }
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
