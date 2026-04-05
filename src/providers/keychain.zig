const std = @import("std");
const keychain_cli = @import("keychain_cli.zig");
const keychain_native = @import("keychain_native.zig");

pub const Backend = enum {
    security_cli,
    native,
};

pub const GenericPasswordTarget = struct {
    service: []const u8,
    account: []const u8,
};

pub const Store = struct {
    backend: Backend,
    io: std.Io,

    pub fn init(backend: Backend, io: std.Io) Store {
        return .{
            .backend = backend,
            .io = io,
        };
    }

    pub fn writeGenericPassword(
        self: Store,
        allocator: std.mem.Allocator,
        target: GenericPasswordTarget,
        value: []const u8,
    ) !void {
        switch (self.backend) {
            .security_cli => try keychain_cli.writeGenericPassword(
                allocator,
                self.io,
                target.service,
                target.account,
                value,
            ),
            .native => try keychain_native.writeGenericPassword(
                target.service,
                target.account,
                value,
            ),
        }
    }

    pub fn readGenericPasswordAlloc(
        self: Store,
        allocator: std.mem.Allocator,
        target: GenericPasswordTarget,
    ) ![]u8 {
        return switch (self.backend) {
            .security_cli => try keychain_cli.readGenericPasswordAlloc(
                allocator,
                self.io,
                target.service,
                target.account,
            ),
            .native => try keychain_native.readGenericPasswordAlloc(
                allocator,
                target.service,
                target.account,
            ),
        };
    }

    pub fn deleteGenericPassword(
        self: Store,
        allocator: std.mem.Allocator,
        target: GenericPasswordTarget,
    ) !void {
        switch (self.backend) {
            .security_cli => try keychain_cli.deleteGenericPassword(
                allocator,
                self.io,
                target.service,
                target.account,
            ),
            .native => {
                try keychain_native.deleteGenericPassword(
                    target.service,
                    target.account,
                );
            },
        }
    }

    pub fn listGenericPasswordAccountsAlloc(
        self: Store,
        allocator: std.mem.Allocator,
        service: []const u8,
    ) ![][]u8 {
        return switch (self.backend) {
            .security_cli => error.UnsupportedOperation,
            .native => try keychain_native.listGenericPasswordAccountsAlloc(
                allocator,
                service,
            ),
        };
    }
};
