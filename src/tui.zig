const std = @import("std");
const vaxis = @import("vaxis");

const ErrorReport = @import("errors.zig").ErrorReport;
const Key = vaxis.Key;
const TextInput = vaxis.widgets.TextInput;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

pub fn collectPrompt(allocator: std.mem.Allocator, diag: *ErrorReport) ![]const u8 {
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

    try render(&vx, tty.writer(), &input, false);

    var show_empty_warning = false;
    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
                if (key.matches(Key.enter, .{}) or key.matches(Key.kp_enter, .{})) {
                    if (input.buf.realLength() == 0) {
                        show_empty_warning = true;
                    } else {
                        return input.buf.toOwnedSlice();
                    }
                } else if (key.matches('c', .{ .ctrl = true })) {
                    diag.setBorrowed(.usage, "Prompt cancelled");
                    return error.UsageError;
                } else {
                    try input.update(.{ .key_press = key });
                    show_empty_warning = false;
                }
            },
        }
        try render(&vx, tty.writer(), &input, show_empty_warning);
    }
}

fn render(vx: *vaxis.Vaxis, tty_writer: *std.Io.Writer, input: *TextInput, show_empty_warning: bool) !void {
    const win = vx.window();
    win.clear();

    const title = vaxis.Cell.Segment{ .text = "Claude Code TUI" };
    _ = win.printSegment(title, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    const help = vaxis.Cell.Segment{ .text = "Enter prompt and press Enter. Ctrl+C to cancel." };
    _ = win.printSegment(help, .{ .row_offset = 1, .col_offset = 0, .wrap = .none });

    if (show_empty_warning and win.height > 2) {
        const warning = vaxis.Cell.Segment{ .text = "Prompt cannot be empty." };
        _ = win.printSegment(warning, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    }

    if (win.height > 0) {
        const height: usize = win.height;
        const input_row: usize = if (height > 3) height - 2 else height - 1;
        const input_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row), .width = null, .height = 1 });
        input_win.clear();
        input.draw(input_win);
        input_win.showCursor(@intCast(input.prev_cursor_col), 0);
    }

    try vx.render(tty_writer);
}
