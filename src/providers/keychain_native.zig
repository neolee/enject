const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.os.tag != .macos) @compileError("The native Keychain prototype currently supports macOS only.");
}

const OSStatus = i32;
const Boolean = u8;
const CFIndex = isize;
const errSecSuccess: OSStatus = 0;
const errSecDuplicateItem: OSStatus = -25299;
const errSecItemNotFound: OSStatus = -25300;
const kCFStringEncodingUTF8: u32 = 0x0800_0100;

const SecKeychainItemOpaque = opaque {};
const SecKeychainItemRef = *SecKeychainItemOpaque;
const CFMutableDictionaryOpaque = opaque {};
const CFDictionaryOpaque = opaque {};
const CFArrayOpaque = opaque {};
const CFStringOpaque = opaque {};
const CFMutableDictionaryRef = *CFMutableDictionaryOpaque;
const CFDictionaryRef = *CFDictionaryOpaque;
const CFArrayRef = *CFArrayOpaque;
const CFStringRef = *CFStringOpaque;
const CFTypeRef = ?*const anyopaque;

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
extern "c" fn SecItemCopyMatching(query: CFDictionaryRef, result: ?*?*anyopaque) callconv(.c) OSStatus;
extern "c" fn CFDictionaryCreateMutable(
    allocator: ?*const anyopaque,
    capacity: CFIndex,
    key_callbacks: ?*const anyopaque,
    value_callbacks: ?*const anyopaque,
) callconv(.c) ?CFMutableDictionaryRef;
extern "c" fn CFDictionarySetValue(dictionary: CFMutableDictionaryRef, key: CFTypeRef, value: CFTypeRef) callconv(.c) void;
extern "c" fn CFDictionaryGetValue(dictionary: CFDictionaryRef, key: CFTypeRef) callconv(.c) CFTypeRef;
extern "c" fn CFArrayGetCount(array: CFArrayRef) callconv(.c) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(array: CFArrayRef, index: CFIndex) callconv(.c) CFTypeRef;
extern "c" fn CFStringCreateWithBytes(
    allocator: ?*const anyopaque,
    bytes: [*]const u8,
    num_bytes: CFIndex,
    encoding: u32,
    is_external_representation: Boolean,
) callconv(.c) ?CFStringRef;
extern "c" fn CFStringGetLength(string: CFStringRef) callconv(.c) CFIndex;
extern "c" fn CFStringGetMaximumSizeForEncoding(length: CFIndex, encoding: u32) callconv(.c) CFIndex;
extern "c" fn CFStringGetCString(
    string: CFStringRef,
    buffer: [*]u8,
    buffer_size: CFIndex,
    encoding: u32,
) callconv(.c) Boolean;

extern const kSecClass: CFTypeRef;
extern const kSecClassGenericPassword: CFTypeRef;
extern const kSecAttrService: CFTypeRef;
extern const kSecAttrAccount: CFTypeRef;
extern const kSecMatchLimit: CFTypeRef;
extern const kSecMatchLimitAll: CFTypeRef;
extern const kSecReturnAttributes: CFTypeRef;
extern const kCFBooleanTrue: CFTypeRef;

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

pub fn listGenericPasswordAccountsAlloc(
    allocator: std.mem.Allocator,
    service: []const u8,
) ![][]u8 {
    const service_cf = try createCFString(service);
    defer CFRelease(service_cf);

    const query = CFDictionaryCreateMutable(null, 4, null, null) orelse return error.OutOfMemory;
    defer CFRelease(query);

    CFDictionarySetValue(query, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(query, kSecAttrService, service_cf);
    CFDictionarySetValue(query, kSecMatchLimit, kSecMatchLimitAll);
    CFDictionarySetValue(query, kSecReturnAttributes, kCFBooleanTrue);

    var result_ref: ?*anyopaque = null;
    const status = SecItemCopyMatching(@ptrCast(query), &result_ref);
    switch (status) {
        errSecSuccess => {},
        errSecItemNotFound => return allocator.alloc([]u8, 0),
        else => try checkStatus(status),
    }
    defer CFRelease(result_ref);

    const array: CFArrayRef = @ptrCast(result_ref.?);
    const count = std.math.cast(usize, CFArrayGetCount(array)) orelse return error.InputTooLong;

    var accounts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (accounts.items) |account| allocator.free(account);
        accounts.deinit(allocator);
    }

    for (0..count) |index| {
        const entry_ref = CFArrayGetValueAtIndex(array, @intCast(index)) orelse continue;
        const entry: CFDictionaryRef = @ptrCast(@constCast(entry_ref));
        const account_ref = CFDictionaryGetValue(entry, kSecAttrAccount) orelse continue;
        try accounts.append(allocator, try copyCFStringAlloc(allocator, @ptrCast(@constCast(account_ref))));
    }

    return accounts.toOwnedSlice(allocator);
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

fn createCFString(bytes: []const u8) !CFStringRef {
    return CFStringCreateWithBytes(
        null,
        bytes.ptr,
        @intCast(bytes.len),
        kCFStringEncodingUTF8,
        0,
    ) orelse error.OutOfMemory;
}

fn copyCFStringAlloc(allocator: std.mem.Allocator, string: CFStringRef) ![]u8 {
    const length = CFStringGetLength(string);
    const max_size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    const buffer = try allocator.alloc(u8, @intCast(max_size));
    errdefer allocator.free(buffer);

    if (CFStringGetCString(string, buffer.ptr, @intCast(buffer.len), kCFStringEncodingUTF8) == 0) {
        return error.InvalidUtf8;
    }

    const nul_index = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return allocator.realloc(buffer, nul_index);
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
