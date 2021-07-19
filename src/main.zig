const std = @import("std");
const time = std.time;
const log = std.log;

const win32 = @import("win32");
const com = win32.system.com;
const core_audio = win32.media.audio.core_audio;
const properties_system = win32.system.properties_system;
const structured_storage = win32.storage.structured_storage;

fn release(com_obj: anytype) void {
    _ = com_obj.IUnknown_Release();
}

fn getDefaultAudioOutputDevice() !*core_audio.IMMDevice {
    var device_enumerator: *core_audio.IMMDeviceEnumerator = undefined;
    {
        const result = com.CoCreateInstance(
            core_audio.CLSID_MMDeviceEnumerator,
            null,
            com.CLSCTX_ALL,
            core_audio.IID_IMMDeviceEnumerator,
            @ptrCast(**c_void, &device_enumerator),
        );

        if (result < 0) {
            log.err("CoCreateInstance FAILED: 0x{X:0>8}", .{result});
            return error.CoCreateInstanceFailed;
        }
    }
    defer release(device_enumerator);

    var device: *core_audio.IMMDevice = undefined;
    {
        const result = device_enumerator.IMMDeviceEnumerator_GetDefaultAudioEndpoint(
            core_audio.EDataFlow.eRender,
            core_audio.ERole.eConsole,
            &device,
        );

        if (result < 0) {
            log.err("GetDefaultAudioEndpoint FAILED: 0x{X:0>8}", .{result});
            return error.GetAudioEndpointFailed;
        }
    }

    return device;
}

fn wideStringZ(wide_str: [*:0]u16) [:0]u16 {
    var idx: usize = 0;
    while (wide_str[idx] != 0) : (idx += 1) {}

    return wide_str[0..idx :0];
}

fn getFriendlyName(device: *core_audio.IMMDevice, buf: []u8) ![]u8 {
    var properties: *properties_system.IPropertyStore = undefined;
    {
        const result = device.IMMDevice_OpenPropertyStore(structured_storage.STGM_READ, &properties);
        if (result < 0) {
            log.err("OpenPropertyStore FAILED: 0x{X:0>8}", .{result});
            return error.OpenPropertyStoreFailed;
        }
    }
    defer release(properties);

    var prop_value: structured_storage.PROPVARIANT = undefined;
    {
        const device_friendly_name = win32.everything.DEVPKEY_Device_FriendlyName;
        const result = properties.IPropertyStore_GetValue(&device_friendly_name, &prop_value);
        if (result < 0) {
            log.err("GetValue FAILED: 0x{X:0>8}", .{result});
            return error.GetValueFailed;
        }
    }
    defer _ = structured_storage.PropVariantClear(&prop_value);

    const wide_name = wideStringZ(prop_value.Anonymous.Anonymous.Anonymous.pwszVal);
    const name_len = try std.unicode.utf16leToUtf8(buf, wide_name);

    return buf[0..name_len];
}

fn getAudioMeterInfo(audio_endpoint: *core_audio.IMMDevice) !*core_audio.IAudioMeterInformation {
    var audio_meter_info: *core_audio.IAudioMeterInformation = undefined;
    {
        const result = audio_endpoint.IMMDevice_Activate(
            core_audio.IID_IAudioMeterInformation,
            @enumToInt(com.CLSCTX_ALL),
            null,
            @ptrCast(**c_void, &audio_meter_info),
        );
        if (result < 0) {
            log.err("Activate FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    return audio_meter_info;
}

fn getEndpointVolume(audio_endpoint: *core_audio.IMMDevice) !*core_audio.IAudioEndpointVolume {
    var endpoint_volume: *core_audio.IAudioEndpointVolume = undefined;
    {
        const result = audio_endpoint.IMMDevice_Activate(
            core_audio.IID_IAudioEndpointVolume,
            @enumToInt(com.CLSCTX_ALL),
            null,
            @ptrCast(**c_void, &endpoint_volume),
        );
        if (result < 0) {
            log.err("Activate FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    return endpoint_volume;
}

fn getPeakVolume(audio_meter_info: *core_audio.IAudioMeterInformation) !f32 {
    var peak_volume: f32 = undefined;
    {
        const result = audio_meter_info.IAudioMeterInformation_GetPeakValue(&peak_volume);
        if (result < 0) {
            log.err("GetPeakValue FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    return peak_volume;
}

fn getMasterVolumeScalar(endpoint_volume: *core_audio.IAudioEndpointVolume) !f32 {
    var master_volume_scalar: f32 = undefined;
    {
        const result = endpoint_volume.IAudioEndpointVolume_GetMasterVolumeLevelScalar(&master_volume_scalar);
        if (result < 0) {
            log.err("Activate FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    return master_volume_scalar;
}

fn renderVolumeBars(peak_volume: f32, master_volume: f32) void {
    const volume_bar = "|" ** 50;
    std.debug.print("\x1b[1F[ {s:<50} ]\x1b[1E[ {s:<50} ]", .{
        volume_bar[0..@floatToInt(u8, peak_volume * 50.0)],
        volume_bar[0..@floatToInt(u8, peak_volume * master_volume * 50.0)],
    });
}

pub fn main() !void {
    // initialise COM
    {
        const result = com.CoInitialize(null);
        if (result < 0) {
            log.err("CoInitialize failed: {}", .{result});
            return error.CoInitializeFailed;
        }
    }
    defer com.CoUninitialize();

    var audio_device = try getDefaultAudioOutputDevice();
    defer release(audio_device);

    var audio_meter_info = try getAudioMeterInfo(audio_device);
    defer release(audio_meter_info);
    var endpoint_volume = try getEndpointVolume(audio_device);
    defer release(endpoint_volume);

    // arbitrary buffer size - big enough for my devices :^)
    var name_buf: [64]u8 = undefined;
    const name = try getFriendlyName(audio_device, &name_buf);

    // print name and hide cursor
    std.debug.print("{s}\n\n\x1b[?25l", .{name});
    defer std.debug.print("\x1b[?25h", .{});

    while (true) {
        renderVolumeBars(
            try getPeakVolume(audio_meter_info),
            try getMasterVolumeScalar(endpoint_volume),
        );
        time.sleep(16 * time.ns_per_ms);
    }
}
