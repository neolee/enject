const std = @import("std");
const support = @import("support.zig");

test "security CLI provider round-trip" {
    const allocator = std.testing.allocator;
    const store = support.store.Store.init(.macos_security_cli, std.testing.io);
    const target = support.store.Target{
        .service = support.test_service,
        .account = "cli-roundtrip",
    };
    try support.expectRoundTrip(store, allocator, target, "cli-test-secret");
}

test "native Keychain provider round-trip" {
    const allocator = std.testing.allocator;
    const store = support.store.Store.init(.macos_native, std.testing.io);
    const target = support.store.Target{
        .service = support.test_service,
        .account = "native-roundtrip",
    };
    try support.expectRoundTrip(store, allocator, target, "native-test-secret");
}
