import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mission_mock.dart';

enum RobotWorkStatus { idle, working, charging }

class RobotAgent {
  const RobotAgent({
    required this.id,
    required this.name,
    required this.color,
    required this.batteryPercent,
    required this.progress,
    required this.workStatus,
    required this.assignedRowIndices,
    required this.position,
    this.headingRad = 0.0,
    this.ns = 'robot',
    this.online = true,
    this.lastSeen,
    this.hasPose = false,
  });

  final int id;
  final String name;
  final Color color;
  final double batteryPercent;
  final double progress;
  final RobotWorkStatus workStatus;
  final List<int> assignedRowIndices;
  final MapPoint position;
  final double headingRad;

  /// ROS namespace this robot was discovered under (`'robot'` = the default,
  /// un-namespaced robot; `'demo'` = the mock-mode robot).
  final String ns;

  /// Liveness from the `<ns>/online` heartbeat. When false, the robot is drawn
  /// greyed at its last known [position].
  final bool online;

  /// Last time a heartbeat was received for this robot (memory only).
  final DateTime? lastSeen;

  /// Whether a real pose has arrived. Until true, [position] is a placeholder
  /// and `distribute()` may seed it from the coverage path.
  final bool hasPose;

  static const List<Color> palette = [
    Color(0xFF1565C0),
    Color(0xFFE65100),
    Color(0xFF558B2F),
    Color(0xFF6A1B9A),
  ];

  RobotAgent copyWith({
    String? name,
    Color? color,
    double? batteryPercent,
    double? progress,
    RobotWorkStatus? workStatus,
    List<int>? assignedRowIndices,
    MapPoint? position,
    double? headingRad,
    String? ns,
    bool? online,
    DateTime? lastSeen,
    bool? hasPose,
  }) =>
      RobotAgent(
        id: id,
        name: name ?? this.name,
        color: color ?? this.color,
        batteryPercent: batteryPercent ?? this.batteryPercent,
        progress: progress ?? this.progress,
        workStatus: workStatus ?? this.workStatus,
        assignedRowIndices: assignedRowIndices ?? this.assignedRowIndices,
        position: position ?? this.position,
        headingRad: headingRad ?? this.headingRad,
        ns: ns ?? this.ns,
        online: online ?? this.online,
        lastSeen: lastSeen ?? this.lastSeen,
        hasPose: hasPose ?? this.hasPose,
      );

  static List<RobotAgent> distribute({
    required List<RobotAgent> robots,
    required List<List<MapPoint>> coverageRows,
  }) {
    if (robots.isEmpty || coverageRows.isEmpty) return robots;
    final n = robots.length;
    final rowsPerRobot = (coverageRows.length / n).ceil();
    return List.generate(n, (i) {
      final start = i * rowsPerRobot;
      final end = math.min(start + rowsPerRobot, coverageRows.length);
      final indices = [for (var j = start; j < end; j++) j];
      final pos = _positionAtProgress(robots[i].progress, indices, coverageRows);
      return robots[i].copyWith(
        assignedRowIndices: indices,
        // Real robots keep their /<ns>/robot_pose; only seed position from the
        // coverage path for robots that have no live pose yet (e.g. demo).
        position: robots[i].hasPose ? robots[i].position : (pos ?? robots[i].position),
      );
    });
  }

  static MapPoint? _positionAtProgress(
    double progress,
    List<int> rowIndices,
    List<List<MapPoint>> coverageRows,
  ) {
    final rows = [
      for (final i in rowIndices)
        if (i < coverageRows.length) coverageRows[i],
    ];
    if (rows.isEmpty) return null;
    final totalPoints = rows.fold<int>(0, (s, r) => s + r.length);
    if (totalPoints == 0) return null;
    var target = (totalPoints * progress).toInt().clamp(0, totalPoints - 1);
    for (final row in rows) {
      if (target < row.length) return row[target];
      target -= row.length;
    }
    return rows.last.last;
  }
}
