const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const print = std.debug.print;

const SymmetricState = @import("symmetric_state.zig").SymmetricState;

const DH = @import("dh.zig").DH;

const protocolFromName = @import("symmetric_state.zig").protocolFromName;
const HandshakeState = @import("handshake_state.zig").HandshakeState;
const patternFromName = @import("handshake_pattern.zig").patternFromName;
const MAX_MESSAGE_LEN = @import("handshake_state.zig").MAX_MESSAGE_LEN;
const HandshakePatternName = @import("handshake_pattern.zig").HandshakePatternName;
const HandshakePattern = @import("handshake_pattern.zig").HandshakePattern;
const MessagePattern = @import("handshake_pattern.zig").MessagePattern;

const CipherStateChaCha = @import("cipher.zig").CipherStateChaCha;

const HashSha256 = @import("hash.zig").HashSha256;
const HashSha512 = @import("hash.zig").HashSha512;
const HashBlake2b = @import("hash.zig").HashBlake2b;
const HashBlake2s = @import("hash.zig").HashBlake2s;
const HashChoice = @import("hash.zig").HashChoice;

const Sha256 = std.crypto.hash.sha2.Sha256;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;

const Sha512 = std.crypto.hash.sha2.Sha512;
const Blake2s256 = std.crypto.hash.blake2.Blake2s256;
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

const CipherState = @import("./cipher.zig").CipherState;
const CipherChoice = @import("./cipher.zig").CipherChoice;
const Hash = @import("hash.zig").Hash;

const Message = struct {
    payload: []const u8,
    ciphertext: []const u8,
};

const Vector = struct {
    protocol_name: []const u8,
    init_prologue: []const u8,
    init_psks: [][]const u8,
    init_ephemeral: []const u8,
    init_remote_static: ?[]const u8 = null,
    init_static: ?[]const u8 = null,
    resp_prologue: []const u8,
    resp_psks: [][]const u8,
    resp_static: ?[]const u8 = null,
    resp_ephemeral: []const u8,
    resp_remote_static: ?[]const u8 = null,
    messages: []const Message,
};

const Vectors = struct {
    vectors: []const Vector,
};

pub fn keypairFromSecretKey(secret_key: []const u8) !DH.KeyPair {
    var sk: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sk, secret_key);
    const pk = try std.crypto.dh.X25519.recoverPublicKey(sk);

    return DH.KeyPair{ .inner = std.crypto.dh.X25519.KeyPair{
        .public_key = pk,
        .secret_key = sk,
    } };
}

test "snow" {
    // const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const snow_txt = try std.fs.cwd().openFile("./testdata/snow.txt", .{});
    const buf: []u8 = try snow_txt.readToEndAlloc(allocator, 1_000_000);

    const should_log = false;

    // Validate snow.txt is loaded correctly
    try std.testing.expect(try std.json.validate(allocator, buf));
    const data = try std.json.parseFromSlice(Vectors, allocator, buf[0..], .{});
    defer data.deinit();

    const total_vector_count = data.value.vectors.len;
    var failed_vector_count: usize = 0;

    std.debug.print("Found {} total vectors.\n", .{total_vector_count});
    var i: usize = 0;
    vector_test: for (data.value.vectors, 0..) |vector, vector_num| {
        const protocol = protocolFromName(vector.protocol_name);

        // See
        if (std.mem.eql(u8, protocol.dh, "448")) continue;
        if (should_log) std.debug.print("\n***** Testing: {s} *****\n", .{vector.protocol_name});

        const init_s = if (vector.init_static) |s| try keypairFromSecretKey(s) else null;
        const init_e = try keypairFromSecretKey(vector.init_ephemeral);

        var init_pk_rs: ?[32]u8 = undefined;
        if (vector.init_remote_static) |rs| {
            _ = try std.fmt.hexToBytes(&init_pk_rs.?, rs);
        }

        var init_prologue_buf: [100]u8 = undefined;
        const init_prologue = try std.fmt.hexToBytes(&init_prologue_buf, vector.init_prologue);

        var j: usize = 0;
        const init_psks = blk: {
            if (vector.init_psks.len > 0) {
                var init_psk_buf = try allocator.alloc(u8, 32 * vector.init_psks.len);
                for (vector.init_psks) |psk| {
                    _ = try std.fmt.hexToBytes(init_psk_buf[j * 32 .. (j + 1) * 32], psk);
                    j += 1;
                }

                break :blk init_psk_buf[0..];
            } else {
                break :blk null;
            }
        };

        var initiator = try HandshakeState.init(
            vector.protocol_name,
            allocator,
            try patternFromName(allocator, protocol.pattern),
            .Initiator,
            init_prologue,
            init_psks,
            .{
                .s = init_s,
                .e = init_e,
                .rs = if (init_pk_rs) |rs| rs else null,
            },
        );
        defer initiator.deinit();

        const resp_s = if (vector.resp_static) |s| try keypairFromSecretKey(s) else null;
        const resp_e = try keypairFromSecretKey(vector.resp_ephemeral);

        var resp_pk_rs: ?[32]u8 = undefined;
        if (vector.resp_remote_static) |rs| {
            _ = try std.fmt.hexToBytes(&resp_pk_rs.?, rs);
        }
        var resp_prologue_buf: [100]u8 = undefined;
        const resp_prologue = try std.fmt.hexToBytes(&resp_prologue_buf, vector.resp_prologue);

        j = 0;
        const resp_psks = blk: {
            if (vector.resp_psks.len > 0) {
                var resp_psk_buf = try allocator.alloc(u8, 32 * vector.init_psks.len);
                for (vector.init_psks) |psk| {
                    _ = try std.fmt.hexToBytes(resp_psk_buf[j * 32 .. (j + 1) * 32], psk);
                    j += 1;
                }

                break :blk resp_psk_buf[0..];
            } else {
                break :blk null;
            }
        };

        var responder = try HandshakeState.init(
            vector.protocol_name,
            allocator,
            try patternFromName(allocator, protocol.pattern),
            .Responder,
            resp_prologue,
            resp_psks,
            .{
                .s = resp_s,
                .e = resp_e,
                .rs = if (resp_pk_rs) |rs| rs else null,
            },
        );
        defer responder.deinit();

        var send_buf = try ArrayList(u8).initCapacity(allocator, MAX_MESSAGE_LEN);
        var recv_buf = try ArrayList(u8).initCapacity(allocator, MAX_MESSAGE_LEN);
        defer send_buf.deinit();
        defer recv_buf.deinit();

        var cipherstate_initiator_enc: CipherState = undefined;
        var cipherstate_initiator_dec: CipherState = undefined;
        var cipherstate_responder_enc: CipherState = undefined;
        var cipherstate_responder_dec: CipherState = undefined;

        for (vector.messages, 0..) |m, k| {
            var sender = if (k % 2 == 0) &initiator else &responder;
            var receiver = if (k % 2 == 0) &responder else &initiator;

            // Test handshake phase
            var payload_buf: [MAX_MESSAGE_LEN]u8 = undefined;
            const payload = try std.fmt.hexToBytes(&payload_buf, m.payload);
            const sender_cipherstates = sender.writeMessage(payload, &send_buf) catch {
                failed_vector_count += 1;
                std.debug.print("Vector \"{s}\" ({}) failed at writeMessage for message {}\n", .{ vector.protocol_name, vector_num + 1, k });
                continue :vector_test;
            };

            var expected_buf: [MAX_MESSAGE_LEN]u8 = undefined;
            var expected = try std.fmt.hexToBytes(&expected_buf, m.ciphertext);

            try std.testing.expectEqualSlices(u8, expected, send_buf.items);

            expected = try std.fmt.hexToBytes(&expected_buf, m.payload);
            const receiver_cipherstates = receiver.readMessage(send_buf.items, &recv_buf) catch {
                failed_vector_count += 1;
                std.debug.print("Vector \"{s}\" ({}) failed at readMessage for message {}\n", .{ vector.protocol_name, vector_num + 1, k });
                continue :vector_test;
            };
            try std.testing.expectEqualSlices(u8, expected, recv_buf.items);

            if (sender_cipherstates != null and receiver_cipherstates != null) {
                if (sender_cipherstates) |cs| {
                    if (k % 2 == 0) {
                        cipherstate_initiator_enc = cs[0];
                        cipherstate_responder_enc = cs[1];
                    } else {
                        cipherstate_responder_enc = cs[0];
                        cipherstate_initiator_enc = cs[1];
                    }
                }

                if (receiver_cipherstates) |cs| {
                    if (k % 2 == 0) {
                        cipherstate_responder_dec = cs[0];
                        cipherstate_initiator_dec = cs[1];
                    } else {
                        cipherstate_initiator_dec = cs[0];
                        cipherstate_responder_dec = cs[1];
                    }
                }
            }

            send_buf.clearAndFree();
            recv_buf.clearAndFree();
        }

        send_buf.clearAndFree();
        recv_buf.clearAndFree();

        try send_buf.resize(MAX_MESSAGE_LEN);
        try recv_buf.resize(MAX_MESSAGE_LEN);

        for (vector.messages, 0..) |m, k| {
            var sender = if (k % 2 == 0) cipherstate_initiator_enc else cipherstate_responder_enc;
            var receiver = if (k % 2 == 0) cipherstate_responder_dec else cipherstate_initiator_dec;

            var payload_buf: [MAX_MESSAGE_LEN]u8 = undefined;
            const payload = try std.fmt.hexToBytes(&payload_buf, m.payload);
            _ = try sender.encryptWithAd(send_buf.items, &[_]u8{}, payload);

            var expected_buf: [MAX_MESSAGE_LEN]u8 = undefined;
            var expected = try std.fmt.hexToBytes(&expected_buf, m.ciphertext);
            try std.testing.expectEqualSlices(u8, expected, send_buf.items[0..expected.len]);

            expected = try std.fmt.hexToBytes(&expected_buf, m.payload);
            try recv_buf.resize(send_buf.items.len);
            _ = try receiver.decryptWithAd(recv_buf.items, &[_]u8{}, send_buf.items);
            try std.testing.expectEqualSlices(u8, expected, recv_buf.items[0..expected.len]);
        }

        i += 1;
    }
    std.debug.print("\n***** {} out of {} vectors passed. *****\n\n", .{ total_vector_count - failed_vector_count, total_vector_count });
}
