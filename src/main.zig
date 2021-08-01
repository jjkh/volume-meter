const std = @import("std");
const win32 = @import("win32");
const Window = @import("win32/Window.zig");
const AudioDevice = @import("win32/AudioDevice.zig");
const checkResult = @import("win32/helper.zig").checkResult;
const CoInitialize = @import("win32/helper.zig").CoInitialize;
const CoUninitialize = @import("win32/helper.zig").CoUninitialize;

const console_mode = std.builtin.mode == .Debug;
const log = std.log;
const com = win32.system.com;

const CONSOLE_BAR_WIDTH = 70;
const AUDIO_MONITOR_TIMER_ID = 1;
const AUDIO_MONITOR_TIMER_PERIOD = if (console_mode) 16 else 100;

const SILENCE_TIMER_ID = 1;

var audio_device: AudioDevice = undefined;

// ======= window handling ==========
const WINAPI = std.os.windows.WINAPI;
const HWND = win32.foundation.HWND;
const wam = win32.ui.windows_and_messaging;

const WmMsg = enum(u32) {
    DESTROY = wam.WM_DESTROY,
    TIMER = wam.WM_TIMER,
    _,
};

pub fn testWndProc(hwnd: HWND, msg: u32, w_param: usize, l_param: isize) callconv(WINAPI) i32 {
    switch (@intToEnum(WmMsg, msg)) {
        .DESTROY => wam.PostQuitMessage(0),
        .TIMER => if (w_param == AUDIO_MONITOR_TIMER_ID) monitorAudioLevels() catch {},
        else => return wam.DefWindowProc(hwnd, msg, w_param, l_param),
    }

    return 0;
}
// =================================

fn monitorAudioLevels() !void {
    const peak_volume = try audio_device.peakVolume();
    const master_volume = try audio_device.masterVolumeScalar();
    if (console_mode) {
        const volume_bar = "|" ** CONSOLE_BAR_WIDTH;
        const format_str = comptime std.fmt.comptimePrint("\x1b[1F[ {{s:<{0}}} ]\x1b[1E[ {{s:<{0}}} ]", .{CONSOLE_BAR_WIDTH});

        std.debug.print(format_str, .{
            volume_bar[0..@floatToInt(u8, peak_volume * @as(f32, CONSOLE_BAR_WIDTH))],
            volume_bar[0..@floatToInt(u8, peak_volume * master_volume * @as(f32, CONSOLE_BAR_WIDTH))],
        });
    }
}

pub fn main() !void {
    try Window.setDpiAware();
    const win = try Window.init("TestWin", "TestWin", testWndProc, .{});
    defer win.deinit();

    // win.show();

    // initialise COM
    try coInitialize();
    defer coUninitialize();

    // get the default audio output device
    audio_device = try AudioDevice.defaultOutputDevice();
    defer audio_device.deinit();

    if (console_mode) {
        // print name and hide cursor
        std.debug.print("{s}\n\n\x1b[?25l", .{try audio_device.friendlyName()});
        defer std.debug.print("\x1b[?25h", .{});
    }
    if (wam.SetTimer(win.handle, AUDIO_MONITOR_TIMER_ID, AUDIO_MONITOR_TIMER_PERIOD, null) == 0)
        return error.ErrorSettingTimer;
    defer _ = wam.KillTimer(win.handle, AUDIO_MONITOR_TIMER_ID);

    while (Window.processMessage()) {}
}
