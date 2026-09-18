import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/paired_robot.dart';
import 'pairing_auth.dart';

/// What the fleet backend knows about a robot
/// (`GET /v1/robots/{id}/status`, docs/BACKEND_ARCHITECTURE.md §7).
class RobotStatus {
  const RobotStatus({
    required this.online,
    required this.lastSeen,
    required this.lan,
    required this.info,
    required this.telemetry,
    required this.sessions,
    required this.fetchedAt,
  });

  final bool online;
  final DateTime? lastSeen;

  /// LAN address the robot reported with its last heartbeat ('' = unknown).
  final String lan;
  final Map<String, dynamic>? info;
  final Map<String, dynamic>? telemetry;
  final int sessions;
  final DateTime fetchedAt;

  factory RobotStatus.fromJson(Map<String, dynamic> j, {DateTime? now}) {
    final seen = j['last_seen'];
    return RobotStatus(
      online: j['online'] == true,
      lastSeen: seen is num
          ? DateTime.fromMillisecondsSinceEpoch(seen.toInt() * 1000)
          : null,
      lan: j['lan']?.toString() ?? '',
      info: j['info'] is Map ? (j['info'] as Map).cast<String, dynamic>() : null,
      telemetry: j['telemetry'] is Map
          ? (j['telemetry'] as Map).cast<String, dynamic>()
          : null,
      sessions: j['sessions'] is num ? (j['sessions'] as num).toInt() : 0,
      fetchedAt: now ?? DateTime.now(),
    );
  }
}

class BackendException implements Exception {
  const BackendException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'BackendException($statusCode, $message)';
}

/// HTTP client for the fleet backend. Every request carries the same
/// X-Mower-* pairing headers as a rosbridge connection.
class BackendClient {
  BackendClient({http.Client? client, Duration timeout = const Duration(seconds: 8)})
    : _client = client ?? http.Client(),
      _timeout = timeout;

  final http.Client _client;
  final Duration _timeout;

  Future<RobotStatus> status(PairedRobot robot, String clientId) async {
    final base = robot.backendBaseUrl;
    if (base.isEmpty) {
      throw const BackendException(0, 'robot has no backend relay');
    }
    final res = await _client
        .get(
          Uri.parse('$base/v1/robots/${robot.id}/status'),
          headers: PairingAuth.headers(robot, clientId),
        )
        .timeout(_timeout);
    if (res.statusCode != 200) {
      String message = 'HTTP ${res.statusCode}';
      try {
        final body = jsonDecode(res.body);
        if (body is Map && body['error'] != null) {
          message = body['error'].toString();
        }
      } catch (_) {
        // keep the HTTP status
      }
      throw BackendException(res.statusCode, message);
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map) {
      throw const BackendException(200, 'bad status body');
    }
    return RobotStatus.fromJson(decoded.cast<String, dynamic>());
  }

  void close() => _client.close();
}
