const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.os.tag != .macos) @compileError("The native Keychain prototype currently supports macOS only.");
}

const OSStatus = i32;
const errSecSuccess: OSStatus = 0;
const errSecDuplicateItem: OSStatus = -25299;
const errSecItemNotFound: OSStatus = -25300;

const SecKeychainItemOpaque = opaque {};
const SecKeychainItemRef = *SecKeychainItemOpaque;

extern "c" fn SecKeychainAddGenericPassword(
    keychain: ?*anyopaque,
    service_name_length: u32,
    service_name: [*]const u8,
    account_name_length: u32,
    account_name: [*]const u8,
    password_length: u32,
    password_data: ?*const anyopaque,
    item_ref: ?*?SecKeychainItemRef,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainFindGenericPassword(
    keychain_or_array: ?*anyopaque,
    service_name_length: u32,
    service_name: [*]const u8,
    account_name_length: u32,
    account_name: [*]const u8,
    password_length: ?*u32,
    password_data: ?*?*anyopaque,
    item_ref: ?*?SecKeychainItemRef,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainItemModifyAttributesAndData(
    item_ref: SecKeychainItemRef,
    attr_list: ?*anyopaque,
    length: u32,
    data: ?*const anyopaque,
) callconv(.c) OSStatus;

extern "c" fn SecKeychainItemDelete(item_ref: SecKeychainItemRef) callconv(.c) OSStatus;
extern "c" fn SecKeychainItemFreeContent(attr_list: ?*anyopaque, data: ?*anyopaque) callconv(.c) OSStatus;
extern "c" fn CFRelease(cf: ?*const anyopaque) callconv(.c) void;

pub fn writeGenericPassword(service: []const u8, account: []const u8, value: []const u8) !void {
    const status = SecKeychainAddGenericPassword(
        null,
        try toU32(service.len),
        service.ptr,
        try toU32(account.len),
        account.ptr,
        try toU32(value.len),
        value.ptr,
        null,
    );

    switch (status) {
        errSecSuccess => return,
        errSecDuplicateItem => {
            const item = try findItem(service, account);
            defer CFRelease(item);

            try checkStatus(SecKeychainItemModifyAttributesAndData(
                item,
                null,
                try toU32(value.len),
                value.ptr,
            ));
        },
        else => try checkStatus(status),
    }
}

pub fn readGenericPasswordAlloc(
    allocator: std.mem.Allocator,
    service: []const u8,
    account: []const u8,
) ![]u8 {
    var password_len: u32 = 0;
    var password_data: ?*anyopaque = null;
    var item_ref: ?SecKeychainItemRef = null;

    const status = SecKeychainFindGenericPassword(
        null,
        try toU32(service.len),
        service.ptr,
        try toU32(account.len),
        account.ptr,
        &password_len,
        &password_data,
        &item_ref,
    );

    if (item_ref) |item| {
        defer CFRelease(item);
    }
    switch (status) {
        errSecSuccess => {},
        else => try checkStatus(status),
    }
    defer _ = SecKeychainItemFreeContent(null, password_data);

    const bytes_ptr: [*]u8 = @ptrCast(password_data.?);
    return allocator.dupe(u8, bytes_ptr[0..password_len]);
}

pub fn deleteGenericPassword(service: []const u8, account: []const u8) !void {
    const item = try findItem(service, account);
    defer CFRelease(item);
    try checkStatus(SecKeychainItemDelete(item));
}

fn findItem(service: []const u8, account: []const u8) !SecKeychainItemRef {
    var item_ref: ?SecKeychainItemRef = null;

    const status = SecKeychainFindGenericPassword(
        null,
        try toU32(service.len),
        service.ptr,
        try toU32(account.len),
        account.ptr,
        null,
        null,
        &item_ref,
    );

    switch (status) {
        errSecSuccess => return item_ref.?,
        else => {
            try checkStatus(status);
            unreachable;
        },
    }
}

fn toU32(value: usize) !u32 {
    return std.math.cast(u32, value) orelse error.InputTooLong;
}

fn checkStatus(status: OSStatus) !void {
    switch (status) {
        errSecSuccess => {},
        errSecItemNotFound => return error.NotFound,
        else => return error.KeychainFailure,
    }
}
