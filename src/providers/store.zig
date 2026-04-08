// Platform-agnostic secret store dispatch layer.
// macOS backends (Security.framework and the `security` CLI) are the first implementation.
// When adding a new platform: add a Backend variant below, add the corresponding
// implementation file in this directory, and extend each switch arm in Store below.

const std = @import("std");
const macos_security_cli = @import("macos_security_cli.zig");
const macos_native = @import("macos_native.zig");

pub const Backend = enum {
    macos_security_cli, // macOS: `security` command-line tool
    macos_native, // macOS: Security.framework via direct C API
    // TODO(platform/linux): linux_secret_service -- libsecret / GNOME Keyring / KWallet via D-Bus
    // TODO(platform/linux): linux_pass_cli       -- `pass` GPG-based password store
    // TODO(platform/windows): windows_wincred    -- Windows Credential Manager via advapi32
};

pub const Target = struct {
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

    pub fn set(
        self: Store,
        allocator: std.mem.Allocator,
        target: Target,
        value: []const u8,
    ) !void {
        // TODO(platform/linux): add .secret_service and .pass_cli cases
        // TODO(platform/windows): add .wincred case
        switch (self.backend) {
            .macos_security_cli => try macos_security_cli.set(
                allocator,
                self.io,
                target.service,
                target.account,
                value,
            ),
            .macos_native => try macos_native.set(
                target.service,
                target.account,
                value,
            ),
        }
    }

    pub fn getAlloc(
        self: Store,
        allocator: std.mem.Allocator,
        target: Target,
    ) ![]u8 {
        // TODO(platform/linux): add .secret_service and .pass_cli cases
        // TODO(platform/windows): add .wincred case
        return switch (self.backend) {
            .macos_security_cli => try macos_security_cli.getAlloc(
                allocator,
                self.io,
                target.service,
                target.account,
            ),
            .macos_native => try macos_native.getAlloc(
                allocator,
                target.service,
                target.account,
            ),
        };
    }

    pub fn delete(
        self: Store,
        allocator: std.mem.Allocator,
        target: Target,
    ) !void {
        // TODO(platform/linux): add .secret_service and .pass_cli cases
        // TODO(platform/windows): add .wincred case
        switch (self.backend) {
            .macos_security_cli => try macos_security_cli.delete(
                allocator,
                self.io,
                target.service,
                target.account,
            ),
            .macos_native => {
                try macos_native.delete(
                    target.service,
                    target.account,
                );
            },
        }
    }

    pub fn listAccountsAlloc(
        self: Store,
        allocator: std.mem.Allocator,
        service: []const u8,
    ) ![][]u8 {
        // TODO(platform/linux): add .secret_service and .pass_cli cases
        // TODO(platform/windows): add .wincred case
        return switch (self.backend) {
            .macos_security_cli => error.UnsupportedOperation,
            .macos_native => try macos_native.listAccountsAlloc(
                allocator,
                service,
            ),
        };
    }
};
