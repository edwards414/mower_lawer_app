import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../models/paired_robot.dart';

/// The pairing hand-shake sent with every rosbridge WebSocket connection
/// (mower_path_planning docs/ROBOT_API.md, "配對"):
///
///   X-Mower-Robot:  robot id
///   X-Mower-Client: stable id of this app install
///   X-Mower-Time:   unix seconds
///   X-Mower-Nonce:  fresh 32 hex chars per connection
///   X-Mower-Mac:    hex(HMAC-SHA256(base32decode(secret), "id\nclient\ntime\nnonce"))
///
/// The robot's rosbridge_auth_proxy verifies it during the HTTP upgrade and
/// answers 401 otherwise.
class PairingAuth {
  const PairingAuth._();

  static const headerRobot = 'X-Mower-Robot';
  static const headerClient = 'X-Mower-Client';
  static const headerTime = 'X-Mower-Time';
  static const headerNonce = 'X-Mower-Nonce';
  static const headerMac = 'X-Mower-Mac';

  static final Random _random = Random.secure();

  static String computeMac({
    required String secret,
    required String robotId,
    required String clientId,
    required int unixSeconds,
    required String nonce,
  }) {
    final key = base32Decode(secret);
    final message = utf8.encode('$robotId\n$clientId\n$unixSeconds\n$nonce');
    return Hmac(sha256, key).convert(message).toString();
  }

  static Map<String, String> headers(
    PairedRobot robot,
    String clientId, {
    DateTime? now,
    String? nonce,
  }) {
    final t = ((now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000);
    final n = nonce ?? newNonce();
    return {
      headerRobot: robot.id,
      headerClient: clientId,
      headerTime: '$t',
      headerNonce: n,
      headerMac: computeMac(
        secret: robot.secret,
        robotId: robot.id,
        clientId: clientId,
        unixSeconds: t,
        nonce: n,
      ),
    };
  }

  static String newNonce() => _hex(16);

  /// A random id for this app install; persisted by the registry.
  static String newClientId() => 'ios-${_hex(8)}';

  static String _hex(int bytes) {
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  /// RFC 4648 base32 (padding optional), as produced by mower-pair.
  static List<int> base32Decode(String input) {
    final s = input.trim().toUpperCase().replaceAll('=', '');
    final out = <int>[];
    var buffer = 0;
    var bits = 0;
    for (final ch in s.split('')) {
      final v = _alphabet.indexOf(ch);
      if (v < 0) {
        throw FormatException('invalid base32 character: $ch');
      }
      buffer = (buffer << 5) | v;
      bits += 5;
      if (bits >= 8) {
        bits -= 8;
        out.add((buffer >> bits) & 0xFF);
        buffer &= (1 << bits) - 1;
      }
    }
    return out;
  }
}
