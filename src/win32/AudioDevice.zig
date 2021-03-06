device: *core_audio.IMMDevice,
friendly_name_buf: [128]u8 = undefined, // arbitrary buffer size
// lazily load as required
audio_meter_info: ?*core_audio.IAudioMeterInformation = null,
endpoint_volume: ?*core_audio.IAudioEndpointVolume = null,
simple_audio_volume: ?*core_audio.ISimpleAudioVolume = null,

const AudioDevice = @This();
const std = @import("std");
const win32 = @import("win32");
usingnamespace @import("helper.zig");

const log = std.log.scoped(.AudioDevice);
const com = win32.system.com;
const core_audio = win32.media.audio.core_audio;
const properties_system = win32.system.properties_system;
const structured_storage = win32.storage.structured_storage;

pub fn defaultOutputDevice() !AudioDevice {
    var device_enumerator = try deviceEnumerator();
    defer release(device_enumerator);

    var device: *core_audio.IMMDevice = undefined;
    try checkResult(
        "GetDefaultAudioEndpoint",
        device_enumerator.IMMDeviceEnumerator_GetDefaultAudioEndpoint(
            core_audio.EDataFlow.eRender,
            core_audio.ERole.eConsole,
            &device,
        ),
    );
    return AudioDevice{ .device = device };
}

pub fn deinit(self: *AudioDevice) void {
    if (self.endpoint_volume) |endpoint_volume|
        release(endpoint_volume);

    if (self.audio_meter_info) |audio_meter_info|
        release(audio_meter_info);

    release(self.device);
}

pub fn friendlyName(self: *AudioDevice) ![]const u8 {
    var properties: *properties_system.IPropertyStore = undefined;
    try checkResult(
        "OpenPropertyStore",
        self.device.IMMDevice_OpenPropertyStore(structured_storage.STGM_READ, &properties),
    );
    defer release(properties);

    var prop_value: structured_storage.PROPVARIANT = undefined;
    const friendly_name_key = win32.everything.DEVPKEY_Device_FriendlyName;
    try checkResult(
        "GetValue",
        properties.IPropertyStore_GetValue(&friendly_name_key, &prop_value),
    );
    defer _ = structured_storage.PropVariantClear(&prop_value);

    const wide_name = wideStringZ(prop_value.Anonymous.Anonymous.Anonymous.pwszVal);
    const name_len = try std.unicode.utf16leToUtf8(&self.friendly_name_buf, wide_name);

    return self.friendly_name_buf[0..name_len];
}

pub fn peakVolume(self: *AudioDevice) !f32 {
    const audio_meter_info = try self.audioMeterInfo();

    var peak_volume: f32 = undefined;
    try checkResult("GetPeakValue", audio_meter_info.IAudioMeterInformation_GetPeakValue(&peak_volume));

    return peak_volume;
}

pub fn masterVolume(self: *AudioDevice) !f32 {
    const endpoint_volume = try self.endpointVolume();

    var master_volume_scalar: f32 = undefined;
    try checkResult(
        "GetMasterVolumeLevelScalar",
        endpoint_volume.IAudioEndpointVolume_GetMasterVolumeLevelScalar(&master_volume_scalar),
    );

    return master_volume_scalar;
}

pub fn setMasterVolume(self: *AudioDevice, volume: f32) !void {
    const endpoint_volume = try self.endpointVolume();
    try checkResult(
        "SetMasterVolumeLevelScalar",
        endpoint_volume.IAudioEndpointVolume_SetMasterVolumeLevelScalar(volume, core_audio.CLSID_GUID_NULL),
    );
}

pub fn isMuted(self: *AudioDevice) !bool {
    const endpoint_volume = try self.endpointVolume();

    var muted: i32 = undefined;
    try checkResult("GetMute", endpoint_volume.IAudioEndpointVolume_GetMute(&muted));

    return muted != 0;
}

pub fn setMute(self: *AudioDevice, to_mute: enum(i32) { Unmute = 0, Mute = 1 }) !void {
    const endpoint_volume = try self.endpointVolume();
    try checkResult("SetMute", endpoint_volume.IAudioEndpointVolume_SetMute(
        @enumToInt(to_mute),
        core_audio.CLSID_GUID_NULL,
    ));
}

pub fn setApplicationVolume(self: *AudioDevice, volume: f32) !void {
    const simple_audio_volume = try self.simpleAudioVolume();
    try checkResult(
        "SetMasterVolume",
        simple_audio_volume.ISimpleAudioVolume_SetMasterVolume(volume, core_audio.CLSID_GUID_NULL),
    );
}

// must be released by caller
fn deviceEnumerator() !*core_audio.IMMDeviceEnumerator {
    var device_enumerator: *core_audio.IMMDeviceEnumerator = undefined;
    try checkResult(
        "CoCreateInstance",
        com.CoCreateInstance(
            core_audio.CLSID_MMDeviceEnumerator,
            null,
            com.CLSCTX_ALL,
            core_audio.IID_IMMDeviceEnumerator,
            @ptrCast(**c_void, &device_enumerator),
        ),
    );

    return device_enumerator;
}

// must be released by caller
fn audioMeterInfo(self: *AudioDevice) !*core_audio.IAudioMeterInformation {
    if (self.audio_meter_info) |audio_meter_info| return audio_meter_info;

    try checkResult(
        "Activate",
        self.device.IMMDevice_Activate(
            core_audio.IID_IAudioMeterInformation,
            @enumToInt(com.CLSCTX_ALL),
            null,
            @ptrCast(**c_void, &self.audio_meter_info),
        ),
    );

    return self.audio_meter_info.?;
}

// must be released by caller
fn endpointVolume(self: *AudioDevice) !*core_audio.IAudioEndpointVolume {
    if (self.endpoint_volume) |endpoint_volume| return endpoint_volume;

    try checkResult(
        "Activate",
        self.device.IMMDevice_Activate(
            core_audio.IID_IAudioEndpointVolume,
            @enumToInt(com.CLSCTX_ALL),
            null,
            @ptrCast(**c_void, &self.endpoint_volume),
        ),
    );

    return self.endpoint_volume.?;
}

fn simpleAudioVolume(self: *AudioDevice) !*core_audio.ISimpleAudioVolume {
    if (self.simple_audio_volume) |simple_audio_volume| return simple_audio_volume;

    var audio_session_manager: *core_audio.IAudioSessionManager = undefined;
    try checkResult(
        "Activate",
        self.device.IMMDevice_Activate(
            core_audio.IID_IAudioSessionManager,
            @enumToInt(com.CLSCTX.INPROC_SERVER),
            null,
            @ptrCast(**c_void, &audio_session_manager),
        ),
    );
    defer release(audio_session_manager);

    var simple_audio_volume: *core_audio.ISimpleAudioVolume = undefined;
    try checkResult(
        "GetSimpleAudioVolume",
        audio_session_manager.IAudioSessionManager_GetSimpleAudioVolume(
            null,
            0,
            &simple_audio_volume,
        ),
    );
    self.simple_audio_volume = simple_audio_volume;

    return simple_audio_volume;
}
