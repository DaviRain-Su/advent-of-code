const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const Errors = @import("errors.zig");
const ErrorReport = Errors.ErrorReport;
const Controller = @import("tui_controller.zig");
const Renderer = @import("tui_renderer.zig");

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
    try Renderer.render(&vx, tty.writer(), &controller.state);

    while (true) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                winsize = ws;
                try vx.resize(allocator, tty.writer(), ws);
                vx.queueRefresh();
            },
            .key_press => |key| {
                const cmd = try controller.handleKeyEvent(allocator, key, diag);
                switch (cmd) {
                    .exit => return error.UsageError,
                    .submit_prompt => {
                        Renderer.render(&vx, tty.writer(), &controller.state) catch |err| {
                            controller.log("render before runWithPrompt failed: {s}", .{@errorName(err)});
                            diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
                            return error.TuiUnavailable;
                        };
                        try controller.executeCommand(allocator, diag, cmd);
                    },
                    .none => {},
                }
            },
        }

        Renderer.render(&vx, tty.writer(), &controller.state) catch |err| {
            controller.log("render loop failed: {s}", .{@errorName(err)});
            diag.setf(.usage, "TUI render failed: {s}", .{@errorName(err)}) catch {};
            return error.TuiUnavailable;
        };
    }
}
