/// signals.zig — signal handlers for zcron
///
/// Three signals are managed here:
///
///   SIGTERM  →  set g_running = false  (graceful shutdown)
///   SIGHUP   →  set g_reload  = true   (reload config file)
///   SIGCHLD  →  reap all terminated children (prevent zombies)
///
/// Signal handlers must be async-signal-safe: no heap allocation, no mutexes,
/// no std.log calls.  Atomic flag writes are the only safe channel back to
/// the main loop.
const std = @import("std");
const posix = std.posix;

// Derive the signal parameter type from posix.Sigaction itself so this
// compiles on any target without relying on auto-generated type names.
const signal_t = blk: {
    const handler_fn_ptr_opt = @FieldType(@FieldType(posix.Sigaction, "handler"), "handler");
    const handler_fn_ptr = @typeInfo(handler_fn_ptr_opt).optional.child;
    const handler_fn = @typeInfo(handler_fn_ptr).pointer.child;
    break :blk @typeInfo(handler_fn).@"fn".params[0].type.?;
};

// ─── Shared flags ─────────────────────────────────────────────────────────────

/// Cleared to false by onSigterm(). The main loop exits when this is false.
var g_running: bool = true;

/// Set to true by onSighup(). The main loop reloads config when this is true
/// and then clears it.
var g_reload: bool = false;

// ─── Public accessors ─────────────────────────────────────────────────────────

pub fn isRunning() bool {
    return @atomicLoad(bool, &g_running, .acquire);
}

pub fn shouldReload() bool {
    return @atomicLoad(bool, &g_reload, .acquire);
}

/// Clear the reload flag after the caller has performed the reload.
pub fn clearReload() void {
    @atomicStore(bool, &g_reload, false, .release);
}

/// Signal the daemon to stop — used by the `quit` REPL command so it follows
/// the same clean-shutdown path as a real SIGTERM.
pub fn requestStop() void {
    @atomicStore(bool, &g_running, false, .release);
}

// ─── Handlers ─────────────────────────────────────────────────────────────────

fn onSigterm(sig: signal_t) callconv(.c) void {
    _ = sig;
    @atomicStore(bool, &g_running, false, .release);
}

fn onSighup(sig: signal_t) callconv(.c) void {
    _ = sig;
    @atomicStore(bool, &g_reload, true, .release);
}

/// Reap every terminated child without blocking.
///
/// The inner loop is required because POSIX does not queue signals: two
/// children exiting simultaneously may produce only one SIGCHLD delivery.
fn onSigchld(sig: signal_t) callconv(.c) void {
    _ = sig;
    const WNOHANG: c_int = 1;
    // Use std.c.waitpid (the raw C function) rather than posix.waitpid.
    // posix.waitpid in Zig 0.15 hits unreachable on ECHILD; the C function
    // simply returns -1, which we treat as "no more children".
    while (true) {
        var status: c_int = 0;
        const pid = std.c.waitpid(-1, &status, WNOHANG);
        if (pid <= 0) return; // 0 = no ready child (WNOHANG), -1 = ECHILD
    }
}

// ─── Installation ─────────────────────────────────────────────────────────────

/// Install SIGTERM, SIGHUP, and SIGCHLD handlers.
/// Call once at startup, before entering the main loop.
pub fn installAll() void {
    installHandler(posix.SIG.TERM, onSigterm, 0);
    installHandler(posix.SIG.HUP, onSighup, 0);
    // SA_RESTART keeps poll() running across SIGCHLD deliveries so that
    // every child exit does not cut the 1-second tick short.
    installHandler(posix.SIG.CHLD, onSigchld, posix.SA.RESTART);
}

fn installHandler(
    signum: signal_t,
    handler: *const fn (signal_t) callconv(.c) void,
    flags: u32,
) void {
    const sa = posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.mem.zeroes(posix.sigset_t),
        .flags = flags,
    };
    posix.sigaction(signum, &sa, null);
}
