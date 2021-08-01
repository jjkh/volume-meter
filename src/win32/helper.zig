const com = @import("win32").system.com;
const log = @import("std").log;

pub fn release(com_obj: anytype) void {
    _ = com_obj.IUnknown_Release();
}

pub fn wideStringZ(wide_str: [*:0]u16) [:0]u16 {
    var idx: usize = 0;
    while (wide_str[idx] != 0) : (idx += 1) {}

    return wide_str[0..idx :0];
}

pub fn checkResult(name: []const u8, result: i32) !void {
    if (result < 0) {
        log.err("{s} FAILED: 0x{X:0>8}", .{ name, result });
        return error.Failed;
    }
}

pub fn coInitialize() !void {
    try checkResult("CoInitialize", com.CoInitialize(null));
}

pub fn coUninitialize() void {
    com.CoUninitialize();
}
