handle: HWND,

const Window = @This();
const std = @import("std");
const L = std.unicode.utf8ToUtf16LeStringLiteral;
const log = std.log.scoped(.window);

const win32 = @import("win32");
usingnamespace win32.foundation;
usingnamespace win32.ui.windows_and_messaging;

const lib_loader = win32.system.library_loader;
const hi_dpi = win32.ui.hi_dpi;
const diag_debug = win32.system.diagnostics.debug;

pub fn init(
    comptime title: []const u8,
    comptime class_name: []const u8,
    window_proc: WNDPROC,
    options: struct {
        window_style: WINDOW_STYLE = .OVERLAPPED,
    },
) !Window {
    const wnd_class = WNDCLASS{
        .style = WNDCLASS_STYLES.initFlags(.{}),
        .lpfnWndProc = window_proc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = lib_loader.GetModuleHandle(null),
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = L(class_name),
    };
    if (RegisterClass(&wnd_class) == 0) {
        log.crit("failed to register class '{s}'", .{class_name});
        return error.Failed;
    }

    const wnd_handle = CreateWindowEx(
        WINDOW_EX_STYLE.initFlags(.{}),
        wnd_class.lpszClassName,
        L(title),
        options.window_style,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        null,
        null,
        wnd_class.hInstance,
        null,
    );
    if (wnd_handle) |handle|
        return Window{ .handle = handle }
    else {
        log.crit("failed to create window '{s}'", .{class_name});
        return error.Failed;
    }
}

pub fn deinit(self: Window) void {
    _ = DestroyWindow(self.handle);
}

pub fn show(self: Window) void {
    _ = ShowWindow(self.handle, SHOW_WINDOW_CMD.initFlags(.{ .SHOWNORMAL = 1 }));
}

// configure default process-level DPI awareness
// requires windows10.0.15063
pub fn setDpiAware() !void {
    const result = hi_dpi.SetProcessDpiAwarenessContext(hi_dpi.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (result < 0) {
        if (diag_debug.GetLastError() == .ERROR_ACCESS_DENIED)
            log.info("DPI awareness already set", .{})
        else
            return error.Failed;
    }
}

pub inline fn processMessage() bool {
    var msg: MSG = undefined;
    if (GetMessage(&msg, null, 0, 0) == 0)
        return false;

    _ = TranslateMessage(&msg);
    _ = DispatchMessage(&msg);

    return true;
}
