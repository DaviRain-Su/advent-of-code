const std = @import("std");
const vaxis = @import("vaxis");
const builtin = @import("builtin");

const App = @import("../app.zig");
const Errors = @import("../errors.zig");
const Agent = @import("../agent.zig");
const ErrorReport = Errors.ErrorReport;
const Controller = @import("tui_controller.zig");
const Renderer = @import("tui_renderer.zig");

const Key = vaxis.Key;

const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
    run_chunk: struct {
        run_id: u64,
        text: []const u8,
    },
    run_done: struct {
        run_id: u64,
        output: []const u8,
    },
    run_error: struct {
        run_id: u64,
        message: []const u8,
    },
};

const StreamSinkContext = struct {
    loop: *vaxis.Loop(Event),
    run_id: u64,
    allocator: std.mem.Allocator,
};

const RunWorkerContext = struct {
    loop: *vaxis.Loop(Event),
    run_id: u64,
    prompt_runner: Controller.PromptRunner,
    prompt: []const u8,
    allocator: std.mem.Allocator,
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

fn streamSinkWrite(ctx: *anyopaque, chunk: []const u8) anyerror!void {
    const stream_ctx: *StreamSinkContext = @ptrCast(@alignCast(ctx));
    if (chunk.len == 0) return;

    const text = try stream_ctx.allocator.dupe(u8, chunk);
    if (!stream_ctx.loop.tryPostEvent(.{ .run_chunk = .{ .run_id = stream_ctx.run_id, .text = text } })) {
        stream_ctx.allocator.free(text);
    }
}

fn runPromptWorker(args: RunWorkerContext) void {
    defer args.allocator.free(args.prompt);

    var thread_diag = Errors.ErrorReport.init(args.allocator);
    defer thread_diag.deinit();

    var stream_ctx = StreamSinkContext{
        .loop = args.loop,
        .run_id = args.run_id,
        .allocator = args.allocator,
    };

    var output = std.ArrayList(u8){};
    defer output.deinit(args.allocator);

    const stream_sink = Agent.StreamSink{
        .ctx = &stream_ctx,
        .write = streamSinkWrite,
    };

    args.prompt_runner(
        args.allocator,
        &thread_diag,
        args.prompt,
        &output,
        null,
        stream_sink,
    ) catch |err| {
        const base_msg = Errors.userFacingMessage(args.allocator, err, &thread_diag) catch "Unexpected runtime error";
        const msg = args.allocator.dupe(u8, base_msg) catch {
            const fallback = "Request failed: unable to format error message.";
            const fallback_msg = args.allocator.dupe(u8, fallback) catch return;
            const posted = args.loop.tryPostEvent(.{
                .run_error = .{ .run_id = args.run_id, .message = fallback_msg },
            });
            if (!posted) {
                args.allocator.free(fallback_msg);
            }
            return;
        };
        const posted = args.loop.tryPostEvent(.{
            .run_error = .{ .run_id = args.run_id, .message = msg },
        });
        if (!posted) {
            args.allocator.free(msg);
        }
        return;
    };

    const final_output = output.toOwnedSlice(args.allocator) catch {
        const fallback_msg = args.allocator.dupe(u8, "Failed to capture assistant output.") catch return;
        const posted = args.loop.tryPostEvent(.{
            .run_error = .{ .run_id = args.run_id, .message = fallback_msg },
        });
        if (!posted) {
            args.allocator.free(fallback_msg);
        }
        return;
    };

    const posted = args.loop.tryPostEvent(.{
        .run_done = .{ .run_id = args.run_id, .output = final_output },
    });
    if (!posted) {
        args.allocator.free(final_output);
    }
}

fn startAsyncRun(
    controller: *Controller.TuiController,
    prompt_runner: Controller.PromptRunner,
    prompt_allocator: std.mem.Allocator,
    loop: *vaxis.Loop(Event),
    thread_allocator: std.mem.Allocator,
) !void {
    const prompt = controller.takePendingPrompt() orelse return;
    const run_id = controller.beginRun();
    const worker_args = RunWorkerContext{
        .loop = loop,
        .run_id = run_id,
        .prompt_runner = prompt_runner,
        .prompt = prompt,
        .allocator = thread_allocator,
    };

    const worker = std.Thread.spawn(.{}, runPromptWorker, .{worker_args}) catch |err| {
        controller.finishRun();
        prompt_allocator.free(prompt);
        return err;
    };
    worker.detach();
}

fn postRunOutputToState(
    controller: *Controller.TuiController,
    allocator: std.mem.Allocator,
    output: []const u8,
) !void {
    if (controller.state.output.items.len == 0 and output.len > 0) {
        try controller.appendOutputChunk(output);
    }

    if (controller.state.output.items.len > 0) {
        try controller.appendMessage(.assistant, controller.state.output.items);
    } else if (output.len > 0) {
        try controller.appendMessage(.assistant, output);
    }

    try controller.appendMessage(.system, "Done.");
    controller.finishRun();
    controller.state.output.clearRetainingCapacity();
    allocator.free(output);
}

fn postRunErrorToState(
    controller: *Controller.TuiController,
    allocator: std.mem.Allocator,
    message: []const u8,
) !void {
    if (controller.state.output.items.len > 0) {
        try controller.appendMessage(.assistant, controller.state.output.items);
    }

    try controller.appendMessage(.system, message);
    controller.finishRun();
    controller.state.output.clearRetainingCapacity();
    allocator.free(message);
}

pub fn run(allocator: std.mem.Allocator, diag: *ErrorReport) !void {
    if (!std.posix.isatty(std.posix.STDIN_FILENO)) {
        diag.setBorrowed(.usage, "TUI requires a TTY. Use -p for CLI mode.");
        return error.TuiUnavailable;
    }

    var controller = Controller.TuiController.init(allocator, .{}, App.runWithPrompt);
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

    var thread_safe_allocator = std.heap.ThreadSafeAllocator{
        .child_allocator = allocator,
    };
    const thread_allocator = thread_safe_allocator.allocator();

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
                const action = try controller.handleEvent(allocator, key, diag);
                if (action == .request_exit) {
                    return error.UsageError;
                }

                if (controller.hasPendingPrompt()) {
                    try Renderer.render(&vx, tty.writer(), &controller.state);
                    startAsyncRun(
                        &controller,
                        App.runWithPrompt,
                        allocator,
                        &loop,
                        thread_allocator,
                    ) catch |err| {
                        if (controller.state.mode == .running) controller.finishRun();
                        try controller.appendMessage(.system, switch (err) {
                            error.OutOfMemory => "Out of memory while starting request.",
                            else => "Failed to start request.",
                        });
                        controller.log("start async run failed: {s}", .{@errorName(err)});
                    };
                }
            },
            .run_chunk => |payload| {
                if (!controller.isCurrentRun(payload.run_id)) {
                    allocator.free(payload.text);
                    continue;
                }

                if (payload.text.len > 0) {
                    try controller.appendOutputChunk(payload.text);
                }
                allocator.free(payload.text);
            },
            .run_done => |payload| {
                if (controller.isCurrentRun(payload.run_id)) {
                    try postRunOutputToState(&controller, allocator, payload.output);
                } else {
                    allocator.free(payload.output);
                }
            },
            .run_error => |payload| {
                if (controller.isCurrentRun(payload.run_id)) {
                    try postRunErrorToState(&controller, allocator, payload.message);
                } else {
                    allocator.free(payload.message);
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
