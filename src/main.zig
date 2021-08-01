const std = @import("std");
const win32 = @import("win32");
const Window = @import("win32/Window.zig");
const AudioDevice = @import("win32/AudioDevice.zig");
const coInitialize = @import("win32/helper.zig").coInitialize;
const coUninitialize = @import("win32/helper.zig").coUninitialize;

const console_mode = std.builtin.mode == .Debug;
const log = std.log;
const com = win32.system.com;
const PlaySound = win32.media.multimedia.PlaySound;
const L = win32.zig.L;

const CONSOLE_BAR_WIDTH = 70;
const AUDIO_MONITOR_TIMER_ID = 1;
const AUDIO_MONITOR_TIMER_PERIOD = if (console_mode) 16 else 100;

const SILENCE_TIMER_ID = 2;
const THRESHOLD_VOLUME = 0.05;
const SILENCE_TIMER_PERIOD = 2 * 60 * 1000;

var window: Window = undefined;
var audio_device: AudioDevice = undefined;
var silence_counter_started = false;

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
        .TIMER => switch (w_param) {
            AUDIO_MONITOR_TIMER_ID => checkAudioLevels() catch reloadAudioDevice(),
            SILENCE_TIMER_ID => preventSilence() catch {
                playBlip();
                reloadAudioDevice();
            },
            else => {},
        },
        else => return wam.DefWindowProc(hwnd, msg, w_param, l_param),
    }

    return 0;
}
// =================================

fn reloadAudioDevice() void {
    log.warn("error checking audio levels - recreating audio device", .{});

    audio_device.deinit();
    audio_device = AudioDevice.defaultOutputDevice() catch |err| {
        log.crit("couldn't get default output device - aborting!! ({})", .{err});
        wam.PostQuitMessage(0);
        return;
    };

    const friendly_name = audio_device.friendlyName() catch "couldn't get name";

    log.info("new device: {s}", .{friendly_name});
}

fn playBlip() void {
    _ = PlaySound(L("assets/short-blip.wav"), null, 0);
}

fn preventSilence() !void {
    const muted = try audio_device.isMuted();
    const master_volume = try audio_device.masterVolume();

    const volume_change_required = muted or master_volume < THRESHOLD_VOLUME;
    if (volume_change_required) {
        try audio_device.setMasterVolume(THRESHOLD_VOLUME);
        try audio_device.setMute(.Unmute);
        try audio_device.setApplicationVolume(1.0);
    } else {
        try audio_device.setApplicationVolume(THRESHOLD_VOLUME / master_volume);
    }

    playBlip();

    if (volume_change_required)
        try audio_device.setMasterVolume(master_volume);
    if (muted)
        try audio_device.setMute(.Mute);
}

fn renderConsoleVolumeBars(peak_volume: f32, peak_master_volume: f32, muted: bool) void {
    const volume_bar = "|" ** CONSOLE_BAR_WIDTH;
    const peak_bar = volume_bar[0..@floatToInt(u8, peak_volume * @as(f32, CONSOLE_BAR_WIDTH))];
    const peak_master_bar = volume_bar[0..@floatToInt(u8, peak_master_volume * @as(f32, CONSOLE_BAR_WIDTH))];

    if (muted) {
        // red lines if muted
        std.debug.print(
            comptime std.fmt.comptimePrint("\x1b[1F[ \x1b[31m{{s:<{0}}}\x1b[0m ]\x1b[1E[ \x1b[31m{{s:<{0}}}\x1b[0m ]", .{CONSOLE_BAR_WIDTH}),
            .{ peak_bar, peak_master_bar },
        );
    } else {
        std.debug.print(
            comptime std.fmt.comptimePrint("\x1b[1F[ {{s:<{0}}} ]\x1b[1E[ {{s:<{0}}} ]", .{CONSOLE_BAR_WIDTH}),
            .{ peak_bar, peak_master_bar },
        );
    }
}

fn checkAudioLevels() !void {
    const peak_volume = try audio_device.peakVolume();
    const master_volume = try audio_device.masterVolume();
    const muted = try audio_device.isMuted();
    const peak_master_volume = peak_volume * master_volume;

    if (console_mode) {
        renderConsoleVolumeBars(peak_volume, peak_master_volume, muted);
    }

    const below_threshold = muted or peak_master_volume < THRESHOLD_VOLUME;
    if (below_threshold and !silence_counter_started) {
        // silence has started
        if (wam.SetTimer(window.handle, SILENCE_TIMER_ID, SILENCE_TIMER_PERIOD, null) == 0)
            return error.ErrorSettingTimer;
        silence_counter_started = true;
    } else if (!below_threshold and silence_counter_started) {
        // audio has started
        _ = wam.KillTimer(window.handle, SILENCE_TIMER_ID);
        silence_counter_started = false;
    }
}

pub fn main() !void {
    try Window.setDpiAware();

    window = try Window.init("TestWin", "TestWin", testWndProc, .{});
    defer window.deinit();

    // window.show();

    // initialise COM
    try coInitialize();
    defer coUninitialize();

    // get the default audio output device
    audio_device = try AudioDevice.defaultOutputDevice();
    defer audio_device.deinit();

    try preventSilence();
    try preventSilence();

    if (console_mode) {
        // print name and hide cursor
        std.debug.print("{s}\n\n\x1b[?25l", .{try audio_device.friendlyName()});
        defer std.debug.print("\x1b[?25h", .{});
    }

    // start timer
    if (wam.SetTimer(window.handle, AUDIO_MONITOR_TIMER_ID, AUDIO_MONITOR_TIMER_PERIOD, null) == 0)
        return error.ErrorSettingTimer;
    defer _ = wam.KillTimer(window.handle, AUDIO_MONITOR_TIMER_ID);

    // pump message loop
    while (Window.processMessage()) {}

    // kill silence timer if running
    // TODO: find a way to do this closer to setting the timer...
    if (silence_counter_started)
        _ = wam.KillTimer(window.handle, SILENCE_TIMER_ID);
}
