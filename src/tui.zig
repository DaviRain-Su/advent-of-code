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

const LogState = struct {
    allocator: std.mem.Allocator,
    messages: *std.ArrayList(Message),
    theme: Theme,
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

    const crash_log = std.fs.cwd().createFile("/tmp/claude_tui_crash.log", .{ .truncate = true }) catch null;
    defer if (crash_log) |file| file.close();
    errdefer |err| {
        if (crash_log) |file| {
            var mutable = file;
            logCrash(&mutable, "tui error: {s}", .{@errorName(err)});
        }
    }

    if (builtin.os.tag != .windows) {
        if (probeTTY()) |err| {
            if (crash_log) |file| {
                var mutable = file;
                logCrash(&mutable, "tui preflight failed open /dev/tty: {s}", .{@tagName(err)});
            }
            diag.setBorrowed(.usage, "TUI requires a controlling terminal (/dev/tty). Use -p for CLI mode.");
            return error.TuiUnavailable;
        }
    }

    var tty_buffer: [4096]u8 = undefined;
    var tty = vaxis.Tty.init(tty_buffer[0..]) catch |err| {
        if (crash_log) |file| {
            var mutable = file;
            logCrash(&mutable, "Failed to initialize TUI: {s}", .{@errorName(err)});
        }
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

    var input_buffer = std.ArrayList(u8){};
    defer input_buffer.deinit(allocator);

    var input_history = std.ArrayList([]const u8){};
    defer {
        for (input_history.items) |item| allocator.free(item);
        input_history.deinit(allocator);
    }
    var history_index: ?usize = null;

    var messages = std.ArrayList(Message){};
    defer {
        for (messages.items) |msg| allocator.free(msg.content);
        messages.deinit(allocator);
    }

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    const theme: Theme = .{};
    var mode: UiMode = .input;

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

    try appendMessage(allocator, &messages, .system, "Welcome to Claude Code TUI.");
    try appendMessage(allocator, &messages, .system, "Ready.");

    try render(&vx, tty.writer(), &messages, &input_buffer, mode, theme);

    var log_state = LogState{ .allocator = allocator, .messages = &messages, .theme = theme };
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
                if (mode == .running) {
                    if (key.matches('c', .{ .ctrl = true })) {
                        diag.setBorrowed(.usage, "Prompt cancelled");
                        return error.UsageError;
                    }
                    break;
                }

                if (key.matches(Key.up, .{})) {
                    if (input_history.items.len > 0) {
                        if (history_index == null) {
                            history_index = input_history.items.len - 1;
                        } else if (history_index.? > 0) {
                            history_index = history_index.? - 1;
                        }
                        const idx = history_index.?;
                        try setInputBuffer(allocator, &input_buffer, input_history.items[idx]);
                    }
                    break;
                }

                if (key.matches(Key.down, .{})) {
                    if (history_index) |idx| {
                        if (idx + 1 < input_history.items.len) {
                            history_index = idx + 1;
                            try setInputBuffer(allocator, &input_buffer, input_history.items[history_index.?]);
                        } else {
                            history_index = null;
                            input_buffer.clearRetainingCapacity();
                        }
                    }
                    break;
                }

                if (key.matches(Key.backspace, .{})) {
                    _ = popUtf8Char(&input_buffer);
                    break;
                }

                if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                    if (input_buffer.items.len == 0) {
                        try appendMessage(allocator, &messages, .system, "Prompt cannot be empty.");
                        break;
                    }

                    const prompt = try allocator.dupe(u8, input_buffer.items);
                    defer allocator.free(prompt);

                    try input_history.append(allocator, try allocator.dupe(u8, prompt));
                    history_index = null;

                    input_buffer.clearRetainingCapacity();
                    output.clearRetainingCapacity();
                    mode = .running;

                    try appendMessage(allocator, &messages, .user, prompt);
                    try appendMessage(allocator, &messages, .system, "Running prompt...");
                    render(&vx, tty.writer(), &messages, &input_buffer, mode, theme) catch |err| {
                        if (crash_log) |file| {
                            var mutable = file;
                            logCrash(&mutable, "render before runWithPrompt failed: {s}", .{@errorName(err)});
                        }
                        diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
                        return error.TuiUnavailable;
                    };

                    if (crash_log) |file| {
                        var mutable = file;
                        logCrash(&mutable, "runWithPrompt start len={d}", .{prompt.len});
                    }

                    App.runWithPrompt(allocator, diag, prompt, &output, sink) catch |err| {
                        output.clearRetainingCapacity();
                        const msg = Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error";
                        defer allocator.free(msg);
                        if (crash_log) |file| {
                            var mutable = file;
                            logCrash(&mutable, "runWithPrompt error: {s}", .{@errorName(err)});
                            logCrash(&mutable, "details: {s}", .{msg});
                        }
                        try appendMessage(allocator, &messages, .system, msg);
                        try output.appendSlice(allocator, msg);
                    };

                    if (crash_log) |file| {
                        var mutable = file;
                        logCrash(&mutable, "runWithPrompt end len={d}", .{output.items.len});
                    }

                    if (output.items.len > 0) {
                        try appendMessage(allocator, &messages, .assistant, output.items);
                    }

                    try appendMessage(allocator, &messages, .system, "Done.");
                    mode = .input;
                    break;
                }

                if (key.matches('c', .{ .ctrl = true })) {
                    diag.setBorrowed(.usage, "Prompt cancelled");
                    return error.UsageError;
                }

                if (key.text) |text| {
                    try input_buffer.appendSlice(allocator, text);
                }
            },
        }

        render(&vx, tty.writer(), &messages, &input_buffer, mode, theme) catch |err| {
            if (crash_log) |file| {
                var mutable = file;
                logCrash(&mutable, "render loop failed: {s}", .{@errorName(err)});
            }
            diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
            return error.TuiUnavailable;
        };
    }
}

fn render(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    messages: *std.ArrayList(Message),
    input_buffer: *std.ArrayList(u8),
    mode: UiMode,
    theme: Theme,
) !void {
    const win = vx.window();
    win.fill(.{ .style = theme.bg });

    const height = win.height;
    const width = win.width;

    if (height < 6 or width < 20) {
        try vx.render(writer);
        return;
    }

    drawTitleBar(win, width, theme);

    const message_area_height: u16 = @intCast(height - 3);
    const max_content_width: usize = if (width > 2) @as(usize, width) - 2 else 0;

    var total_lines: usize = 0;
    for (messages.items) |msg| {
        var iter = std.mem.splitScalar(u8, msg.content, '\n');
        while (iter.next()) |_| {
            total_lines += 1;
        }
    }

    const max_display: usize = message_area_height;
    const lines_to_skip: usize = if (total_lines > max_display) total_lines - max_display else 0;

    var row: u16 = 1;
    var skipped: usize = 0;

    for (messages.items) |msg| {
        if (row >= message_area_height + 1) break;

        const prefix = switch (msg.role) {
            .user => "> ",
            .assistant => "< ",
            .system => "  ",
        };
        const style = switch (msg.role) {
            .user => theme.user,
            .assistant => theme.assistant,
            .system => theme.system,
        };

        var first_line = true;
        var line_iter = std.mem.splitScalar(u8, msg.content, '\n');
        while (line_iter.next()) |line| {
            if (skipped < lines_to_skip) {
                skipped += 1;
                first_line = false;
                continue;
            }

            if (row >= message_area_height + 1) break;

            const prefix_text = if (first_line) prefix else "  ";
            const prefix_seg = vaxis.Segment{ .text = prefix_text, .style = style };
            _ = win.print(&.{prefix_seg}, .{ .row_offset = row, .col_offset = 0, .wrap = .none });
            first_line = false;

            const content = if (line.len > max_content_width) line[0..max_content_width] else line;
            const content_seg = vaxis.Segment{ .text = content, .style = style };
            _ = win.print(&.{content_seg}, .{ .row_offset = row, .col_offset = 2, .wrap = .none });

            row += 1;
        }
    }

    const sep_row: u16 = @intCast(height - 2);
    drawSeparator(win, width, sep_row, theme);

    const input_row: u16 = @intCast(height - 1);
    const input_prefix = vaxis.Segment{ .text = "> ", .style = theme.input_prompt };
    _ = win.print(&.{input_prefix}, .{ .row_offset = input_row, .col_offset = 0, .wrap = .none });

    if (input_buffer.items.len > 0) {
        const max_width: usize = if (width > 2) @as(usize, width) - 2 else 0;
        const display = tailSliceByDisplayWidth(input_buffer.items, max_width);
        const input_seg = vaxis.Segment{ .text = display, .style = theme.input_text };
        _ = win.print(&.{input_seg}, .{ .row_offset = input_row, .col_offset = 2, .wrap = .none });
    }

    const display_len = displayWidth(input_buffer.items);
    const cursor_col: u16 = @intCast(@min(display_len + 2, width - 1));
    win.showCursor(cursor_col, input_row);

    _ = mode;

    try vx.render(writer);
    try writer.flush();
}

fn drawTitleBar(win: vaxis.Window, width: u16, theme: Theme) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        win.writeCell(col, 0, .{ .char = .{ .grapheme = " ", .width = 1 }, .style = theme.title_bar });
    }

    var title_buf: [200]u8 = undefined;
    const title_text = std.fmt.bufPrint(&title_buf, " Claude Code  ({s}) ", .{resolveModelLabel()}) catch " Claude Code ";
    const title_len: u16 = @intCast(title_text.len);
    const start_col: u16 = if (width > title_len) (width - title_len) / 2 else 0;
    const title_seg = vaxis.Segment{ .text = title_text, .style = theme.title_bar };
    _ = win.print(&.{title_seg}, .{ .row_offset = 0, .col_offset = start_col, .wrap = .none });
}

fn drawSeparator(win: vaxis.Window, width: u16, row: u16, theme: Theme) void {
    var col: u16 = 0;
    while (col < width) : (col += 1) {
        win.writeCell(col, row, .{ .char = .{ .grapheme = "─", .width = 1 }, .style = theme.separator });
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

fn logSinkWrite(ctx: *anyopaque, msg: []const u8) void {
    const state: *LogState = @ptrCast(@alignCast(ctx));
    var it = std.mem.splitScalar(u8, msg, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        appendMessage(state.allocator, state.messages, .system, line) catch {};
    }
}
