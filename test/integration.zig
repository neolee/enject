const std = @import("std");
const enject = @import("enject");

const test_service = "com.github.neolee.enject.tests";
const keychain = enject.providers.keychain;

test "security CLI provider round-trip" {
    const allocator = std.testing.allocator;
    const store = keychain.Store.init(.security_cli, std.testing.io);
    const target = keychain.GenericPasswordTarget{
        .service = test_service,
        .account = "cli-roundtrip",
    };
    try expectRoundTrip(store, allocator, target, "cli-test-secret");
}

test "native Keychain provider round-trip" {
    const allocator = std.testing.allocator;
    const store = keychain.Store.init(.native, std.testing.io);
    const target = keychain.GenericPasswordTarget{
        .service = test_service,
        .account = "native-roundtrip",
    };
    try expectRoundTrip(store, allocator, target, "native-test-secret");
}

fn expectRoundTrip(
    store: keychain.Store,
    allocator: std.mem.Allocator,
    target: keychain.GenericPasswordTarget,
    expected_value: []const u8,
) !void {
    store.deleteGenericPassword(allocator, target) catch |err| switch (err) {
        error.NotFound => {},
        else => return err,
    };

    try store.writeGenericPassword(allocator, target, expected_value);

    const loaded = try store.readGenericPasswordAlloc(allocator, target);
    defer allocator.free(loaded);

    try std.testing.expectEqualStrings(expected_value, loaded);

    try store.deleteGenericPassword(allocator, target);
    _ = store.readGenericPasswordAlloc(allocator, target) catch |err| switch (err) {
        error.NotFound => return,
        else => return err,
    };

    return error.ExpectedMissingPassword;
}
