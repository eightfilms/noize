//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");

const X25519 = std.crypto.dh.X25519;

const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha512 = std.crypto.hash.sha2.Sha512;
const Blake2s256 = std.crypto.hash.blake2.Blake2s256;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

const CipherState = @import("./cipher.zig").CipherState;
const SymmetricState = @import("./symmetric_state.zig").SymmetricState;

const HandshakeState = struct {
    const Self = @This();

    symmetric_state: SymmetricState,
    dh: DH,
};

/// Instantiates a Noise hash function.
///
/// Only these hash functions are supported in accordance with the spec: `Sha256`, `Sha512`, `Blake2s256`, `Blake2b512`.
///
/// https://noiseprotocol.org/noise.html#hash-functions
pub fn Hash(comptime H: type) type {
    const _Hash = H;

    const HASHLEN = comptime switch (H) {
        Sha256, Blake2s256 => 32,
        Sha512, Blake2b512 => 64,
        else => @compileError(std.fmt.comptimePrint("Unsupported hash: {any}", .{H})),
    };

    const BLOCKLEN = comptime switch (H) {
        Sha256, Blake2s256 => 64,
        Sha512, Blake2b512 => 128,
        else => @compileError(std.fmt.comptimePrint("Unsupported hash: {any}", .{H})),
    };

    return struct {
        pub const len = HASHLEN;

        const Self = @This();

        fn init() Self {
            return .{};
        }

        /// Hashes some arbitrary-length data with a collision-resistant cryptographic hash function.
        ///
        /// Returns an output of `HASHLEN` bytes.
        fn hash(input: []const u8) [HASHLEN]u8 {
            var out: [HASHLEN]u8 = undefined;
            _Hash.hash(input, &out, .{});
            return out;
        }

        /// https://www.ietf.org/rfc/rfc2104.txt
        fn hmacHash(allocator: std.mem.Allocator, key: []const u8, data: []const u8) ![HASHLEN]u8 {
            const B = BLOCKLEN;

            // 1. append zeroes at the end of K to create a B byte string
            var zeroes = try allocator.alloc(u8, B - key.len);
            defer allocator.free(zeroes);
            for (0..zeroes.len) |i| {
                zeroes[i] = 0;
            }
            var appended = try std.mem.concat(allocator, u8, &[_][]const u8{ key, zeroes[0..] });
            defer allocator.free(appended);

            // (3) append 'text' to B byte string from (2)
            var stream = try std.mem.concat(allocator, u8, &[_][]const u8{ appended, data });
            defer allocator.free(stream);

            // (2) XOR B byte string with ipad
            for (0..appended.len) |i| {
                appended[i] ^= 0x36;
            }

            // (4) apply H to stream generated in (3)
            const h = hash(stream);

            // (5) XOR B byte string with opad
            for (0..stream.len) |i| {
                stream[i] ^= 0x5c;
            }

            // (6) append 'h' from (4) to B byte string from (5)
            const hh = try std.mem.concat(allocator, u8, &[_][]const u8{ stream, &h });
            defer allocator.free(hh);

            // (7) apply H to stream generated in (6) and output the result
            return hash(hh);
        }

        // TODO: test
        fn HKDF(
            allocator: std.mem.Allocator,
            chaining_key: []const u8,
            input_key_material: []const u8,
            num_outputs: u8,
        ) !struct { [HASHLEN]u8, [HASHLEN]u8, ?[HASHLEN]u8 } {
            std.debug.assert(input_key_material.len == 0 or input_key_material.len == 32);

            const temp_key = try hmacHash(allocator, chaining_key, input_key_material);
            errdefer allocator.free(&temp_key);
            const output1 = try hmacHash(allocator, &temp_key, &[_]u8{0x01});
            errdefer allocator.free(&output1);
            const bytes = [_]u8{0x02};
            const data = try std.mem.concat(allocator, u8, &[_][]const u8{ &output1, &bytes });
            defer allocator.free(data);
            const output2 = try hmacHash(allocator, &temp_key, data);
            errdefer allocator.free(&output2);
            if (num_outputs == 2) return .{ output1, output2, null };
            const data2 = try std.mem.concat(allocator, u8, &[_][]const u8{ &output1, &bytes });
            defer allocator.free(data2);
            const output3 = try hmacHash(allocator, &temp_key, data2);
            errdefer allocator.free(&output3);

            return .{ output1, output2, output3 };
        }
    };
}

test "hmacHash" {
    const h = Hash(Sha256);
    const ck = [_]u8{1} ** 32;
    const ikm = [_]u8{};
    const allocator = std.testing.allocator;
    const output = try h.HKDF(allocator, &ck, &ikm, 3);
    std.debug.print("out = {any}", .{output});
}

test "hash" {
    const h = Hash(Sha256);
    const ck = [_]u8{1} ** 32;
    const ikm = [_]u8{};
    const allocator = std.testing.allocator;
    const output = try h.HKDF(allocator, &ck, &ikm, 3);
    errdefer allocator.free(&output[0]);
    errdefer allocator.free(&output[1]);
    if (output[2]) |o| {
        errdefer allocator.free(&o);
    }
    std.debug.print("out = {any}", .{output});
}

/// A Noise Diffie-Hellman function.
///
/// Only Curve25519 is supported, since zig stdlib does not have Curve448 support.
fn DH() type {
    const DHLEN = 32;

    const Keypair = X25519.Keypair;

    const Self = @This();

    return struct {
        /// Generates a new Diffie-Hellman key pair. A DH key pair consists of public_key and private_key elements.
        /// A public_key represents an encoding of a DH public key into a byte sequence of length `DHLEN`.
        /// The public_key encoding details are specific to each set of DH functions.
        ///
        /// Returns the `Keypair`.
        fn generateKeypair(seed: ?[32]u8) Keypair {
            return X25519.KeyPair.create(seed);
        }

        /// Performs a Diffie-Hellman calculation between the private key in `Keypair` and the `public_key`.
        ///
        /// Returns an output sequence of bytes of length `DHLEN`.
        fn DH(self: *Self, public_key: [X25519.public_length]u8) [DHLEN]u8 {
            const shared_secret = try X25519.scalarmult(self.secret_key, public_key);
            return shared_secret;
        }
    };
}

test {
    _ = @import("cipher.zig");
    _ = @import("symmetric_state.zig");
}
