/// An unfinished coverage execution the robot can continue, from
/// `checkpoint` in the /coverage_progress_status answer (a
/// mower_interface/CoverageProgress). The robot keeps it on disk, so it is
/// still there after the app or the robot restarts.
class CoverageCheckpoint {
  const CoverageCheckpoint({
    required this.missionId,
    required this.zoneId,
    required this.completedSegments,
    required this.totalSegments,
    this.stopReason,
  });

  /// The execution that wrote it; every start and every resume has its own.
  final String missionId;
  final int zoneId;
  final int completedSegments;
  final int totalSegments;

  /// Why it stopped, when that was not a person; see [_stopReason].
  final String? stopReason;

  /// How the health gate's stop reads in the robot's status (mower_nav).
  static const safetyStopMarker = 'Navigation safety stop: ';

  /// Null unless the robot says it can be continued and it makes sense here.
  ///
  /// `checkpoint_available` alone is not enough: the leg of a zone sequence
  /// that drives a channel writes a checkpoint too, with zone -1, and
  /// /resume_coverage can only look up zones (it answers "Zone not found").
  /// A robot from before that fix still reports it, so this stays.
  ///
  /// [progress] is the same answer's `progress`, the last execution.
  static CoverageCheckpoint? fromJson(Object? json, {Object? progress}) {
    if (json is! Map || json['checkpoint_available'] != true) {
      return null;
    }
    final zoneId = _int(json['zone_id']);
    final completed = _int(json['completed_segments']);
    final total = _int(json['total_segments']);
    if (zoneId == null ||
        completed == null ||
        total == null ||
        zoneId < 0 ||
        completed < 0 ||
        completed >= total ||
        json['status_text'] == 'succeeded') {
      return null;
    }
    final missionId = json['mission_id']?.toString() ?? '';
    return CoverageCheckpoint(
      missionId: missionId,
      zoneId: zoneId,
      completedSegments: completed,
      totalSegments: total,
      stopReason: _stopReason(progress, missionId),
    );
  }

  /// What a person should know about how this execution ended: a safety stop
  /// (status canceled, the reason in its message) or a failure. Nothing for a
  /// stop a person asked for, which is also all a robot from before the
  /// safety-stop message reports for a trip.
  static String? _stopReason(Object? progress, String missionId) {
    if (progress is! Map || progress['mission_id']?.toString() != missionId) {
      return null;
    }
    final message = progress['message']?.toString().trim() ?? '';
    final safety = message.indexOf(safetyStopMarker);
    if (safety >= 0) {
      return '安全停止：${message.substring(safety + safetyStopMarker.length)}';
    }
    return progress['status'] == 6 && message.isNotEmpty
        ? '任務失敗：$message'
        : null;
  }

  static int? _int(Object? value) => value is num ? value.toInt() : null;
}

/// Whether the `progress` of a /coverage_progress_status answer is an
/// execution still going (navigating to start, running, canceling). The
/// server reports a terminal navigation state a moment before it finishes
/// the progress, so an answer can still say this just after a stop.
bool coverageProgressIsActive(Object? progress) {
  if (progress is! Map) {
    return false;
  }
  final status = progress['status'];
  return status == 1 || status == 2 || status == 3;
}
