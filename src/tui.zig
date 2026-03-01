const std = @import("std");
const vaxis = @import("vaxis");

const App = @import("app.zig");
const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const Key = vaxis.Key;
const TextInput = vaxis.widgets.TextInput;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

const UiMode = enum {
    input,
    running,
    done,
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

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var mode: UiMode = .input;
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

    try render(&vx, tty.writer(), &input, mode, show_empty_warning, output.items);

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
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

                                output.clearRetainingCapacity();
                                mode = .running;
                                try render(&vx, tty.writer(), &input, mode, show_empty_warning, output.items);

                                App.runWithPrompt(allocator, diag, prompt, &output) catch |err| {
                                    output.clearRetainingCapacity();
                                    const msg = Errors.userFacingMessage(allocator, err, diag) catch "Unexpected runtime error";
                                    defer allocator.free(msg);
                                    try output.appendSlice(allocator, msg);
                                };

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
        try render(&vx, tty.writer(), &input, mode, show_empty_warning, output.items);
    }
}

fn render(
    vx: *vaxis.Vaxis,
    tty_writer: *std.Io.Writer,
    input: *TextInput,
    mode: UiMode,
    show_empty_warning: bool,
    output: []const u8,
) !void {
    const win = vx.window();
    win.clear();

    const title = vaxis.Cell.Segment{ .text = "Claude Code TUI" };
    _ = win.printSegment(title, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

    const help_text = switch (mode) {
        .input => "Enter prompt and press Enter. Ctrl+C to cancel.",
        .running => "Running...",
        .done => "Press Enter for a new prompt. Press q to quit.",
    };
    const help = vaxis.Cell.Segment{ .text = help_text };
    _ = win.printSegment(help, .{ .row_offset = 1, .col_offset = 0, .wrap = .none });

    if (show_empty_warning and win.height > 2) {
        const warning = vaxis.Cell.Segment{ .text = "Prompt cannot be empty." };
        _ = win.printSegment(warning, .{ .row_offset = 2, .col_offset = 0, .wrap = .none });
    }

    const height: usize = win.height;
    const width: usize = win.width;
    if (height > 4 and width > 0) {
        const output_height = height - 4;
        const output_win = win.child(.{ .x_off = 0, .y_off = 3, .width = @intCast(width), .height = @intCast(output_height) });
        output_win.clear();
        if (output.len > 0) {
            const output_segment = vaxis.Cell.Segment{ .text = output };
            _ = output_win.printSegment(output_segment, .{ .row_offset = 0, .col_offset = 0, .wrap = .grapheme });
        }
    }

    if (mode == .input and height > 0) {
        const input_row: usize = if (height > 3) height - 1 else height - 1;
        const input_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row), .width = @intCast(width), .height = 1 });
        input_win.clear();
        input.draw(input_win);
        input_win.showCursor(input.prev_cursor_col, 0);
    } else {
        win.hideCursor();
    }

    try vx.render(tty_writer);
}
