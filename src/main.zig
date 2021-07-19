const std = @import("std");
const time = std.time;
const log = std.log;
pub const log_level = log.Level.info;

const win32 = @import("win32");
const com = win32.system.com;
const core_audio = win32.media.audio.core_audio;
const properties_system = win32.system.properties_system;
const structured_storage = win32.storage.structured_storage;

fn release(com_obj: anytype) void {
    _ = com_obj.IUnknown_Release();
}

fn get_default_device() !*core_audio.IMMDevice {
    var enumerator: *core_audio.IMMDeviceEnumerator = undefined;
    {
        const result = com.CoCreateInstance(
            core_audio.CLSID_MMDeviceEnumerator,
            null,
            com.CLSCTX_ALL,
            core_audio.IID_IMMDeviceEnumerator,
            @ptrCast(**c_void, &enumerator),
        );

        if (result < 0) {
            log.err("CoCreateInstance FAILED: 0x{X:0>8}", .{result});
            return error.CoCreateInstanceFailed;
        }
    }
    defer release(enumerator);
    log.debug("enumerator: {s}\n", .{enumerator});

    var device: *core_audio.IMMDevice = undefined;
    {
        const result = enumerator.IMMDeviceEnumerator_GetDefaultAudioEndpoint(
            core_audio.EDataFlow.eRender,
            core_audio.ERole.eConsole,
            &device,
        );

        if (result < 0) {
            log.err("GetDefaultAudioEndpoint FAILED: 0x{X:0>8}", .{result});
            return error.GetAudioEndpointFailed;
        }
    }
    log.debug("default audio endpoint: {s}\n", .{device});

    return device;
}

fn wide_string_z(wide_str: [*:0]u16) [:0]u16 {
    var idx: usize = 0;
    while (wide_str[idx] != 0) : (idx += 1) {}

    return wide_str[0..idx :0];
}

fn get_device_name(device: *core_audio.IMMDevice, buf: []u8) ![]u8 {
    var properties: *win32.everything.IPropertyStore = undefined;
    {
        const result = device.IMMDevice_OpenPropertyStore(win32.everything.STGM_READ, &properties);
        if (result < 0) {
            log.err("OpenPropertyStore FAILED: 0x{X:0>8}", .{result});
            return error.OpenPropertyStoreFailed;
        }
    }
    defer release(properties);
    log.debug("device props: {s}", .{properties});

    var prop_value: structured_storage.PROPVARIANT = undefined;
    {
        const result = properties.IPropertyStore_GetValue(&win32.everything.DEVPKEY_Device_FriendlyName, &prop_value);
        if (result < 0) {
            log.err("GetValue FAILED: 0x{X:0>8}", .{result});
            return error.GetValueFailed;
        }
    }
    defer _ = structured_storage.PropVariantClear(&prop_value);
    log.debug("prop value: {s}", .{prop_value});

    const wide_name = wide_string_z(prop_value.Anonymous.Anonymous.Anonymous.pwszVal);
    const name_len = try std.unicode.utf16leToUtf8(buf, wide_name);

    return buf[0..name_len];
}

fn get_audio_meter_info(audio_endpoint: *core_audio.IMMDevice) !*core_audio.IAudioMeterInformation {
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
    log.debug("audio meter information: {s}\n", .{audio_meter_info});

    return audio_meter_info;
}

fn get_audio_endpoint_volume(audio_endpoint: *core_audio.IMMDevice) !*core_audio.IAudioEndpointVolume {
    var audio_endpoint_volume: *core_audio.IAudioEndpointVolume = undefined;
    {
        const result = audio_endpoint.IMMDevice_Activate(
            core_audio.IID_IAudioEndpointVolume,
            @enumToInt(com.CLSCTX_ALL),
            null,
            @ptrCast(**c_void, &audio_endpoint_volume),
        );
        if (result < 0) {
            log.err("Activate FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    log.debug("audio volume endpoint: {s}\n", .{audio_endpoint_volume});

    return audio_endpoint_volume;
}

fn get_peak_volume(audio_meter_info: *core_audio.IAudioMeterInformation) !f32 {
    var peak_volume: f32 = undefined;
    {
        const result = audio_meter_info.IAudioMeterInformation_GetPeakValue(&peak_volume);
        if (result < 0) {
            log.err("GetPeakValue FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    log.debug("peak: {}\n", .{peak_volume});

    return peak_volume;
}

fn get_master_volume_scalar(audio_endpoint_volume: *core_audio.IAudioEndpointVolume) !f32 {
    var master_volume_scalar: f32 = undefined;
    {
        const result = audio_endpoint_volume.IAudioEndpointVolume_GetMasterVolumeLevelScalar(&master_volume_scalar);
        if (result < 0) {
            log.err("Activate FAILED: 0x{X:0>8}", .{result});
            return error.Failed;
        }
    }
    log.debug("master volume scalar: {}", .{master_volume_scalar});

    return master_volume_scalar;
}

fn render_volume_bars(peak_volume: f32, master_volume: f32) void {
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

    // get default device audio meter info
    var default_device = try get_default_device();
    defer release(default_device);

    var audio_meter_info = try get_audio_meter_info(default_device);
    defer release(audio_meter_info);
    var audio_endpoint_volume = try get_audio_endpoint_volume(default_device);
    defer release(audio_endpoint_volume);

    var name_buf = [_]u8{0} ** 64;
    const name = try get_device_name(default_device, &name_buf);

    // print name and hide cursor
    std.debug.print("{s}\n\n\x1b[?25l", .{name});
    defer std.debug.print("\x1b[?25h", .{});

    while (true) {
        render_volume_bars(try get_peak_volume(audio_meter_info), try get_master_volume_scalar(audio_endpoint_volume));
        time.sleep(16 * time.ns_per_ms);
    }
}
