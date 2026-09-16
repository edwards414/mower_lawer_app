import 'dart:convert';

/// Robot ⇄ app API contract (mower_path_planning docs/ROBOT_API.md).
///
/// The robot publishes its `api_version` on `/robot/info`; this app can talk
/// to any robot whose number is inside this range. Bump the range when the
/// app adopts a new robot API; keep the lower bound as long as the app still
/// works with older robots.
const int kMinRobotApiVersion = 1;
const int kMaxRobotApiVersion = 1;

enum RobotCompatibility {
  /// No `/robot/info` received yet (old robot without it, or not connected).
  unknown,
  compatible,

  /// Robot API older than this app supports → update the robot.
  robotTooOld,

  /// Robot API newer than this app supports → update the app.
  appTooOld,
}

/// Build identity of one component as reported by `/robot/info`.
class ComponentVersion {
  const ComponentVersion({
    this.version = '',
    this.gitSha = '',
    this.buildUnix,
    this.dirty = false,
    this.unversioned = false,
  });

  final String version;
  final String gitSha;
  final int? buildUnix;
  final bool dirty;
  final bool unversioned;

  bool get isEmpty => version.isEmpty && gitSha.isEmpty;

  /// `0.6.0+f22f2465` / `0.6.0+f22f2465 (dirty)` / `—`
  String get label {
    if (isEmpty) return '—';
    final sha = gitSha.isEmpty ? '' : '+${gitSha.substring(0, gitSha.length.clamp(0, 8))}';
    final tags = [
      if (dirty) 'dirty',
      if (unversioned) 'unversioned',
    ];
    return '$version$sha${tags.isEmpty ? '' : ' (${tags.join(', ')})'}';
  }

  factory ComponentVersion.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const ComponentVersion();
    return ComponentVersion(
      version: j['version']?.toString() ?? '',
      gitSha: j['git_sha']?.toString() ?? '',
      buildUnix: (j['build_unix'] as num?)?.toInt(),
      dirty: j['dirty'] == true,
      unversioned: j['unversioned'] == true,
    );
  }
}

/// Host-side update progress (`update` in `/robot/info`), written by
/// deploy/host/mower-update.sh on the robot.
class UpdateStatus {
  const UpdateStatus({this.state = '', this.message = '', this.time});

  final String state;
  final String message;
  final int? time;

  bool get inProgress =>
      state == 'pulling' || state == 'restarting' || state == 'rebooting';
  bool get failed => state == 'failed';

  factory UpdateStatus.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const UpdateStatus();
    return UpdateStatus(
      state: j['state']?.toString() ?? '',
      message: j['message']?.toString() ?? '',
      time: (j['time'] as num?)?.toInt(),
    );
  }
}

/// One `/robot/info` message (std_msgs/String carrying JSON).
class RobotInfo {
  const RobotInfo({
    required this.robotId,
    required this.apiVersion,
    required this.software,
    required this.imageTag,
    required this.imageDigest,
    required this.firmwareRunning,
    required this.firmwareBundled,
    required this.firmwareUpToDate,
    required this.firmwareSyncAction,
    required this.firmwareSyncError,
    required this.update,
    required this.busy,
    required this.uptimeS,
  });

  final String robotId;
  final int apiVersion;
  final ComponentVersion software;
  final String imageTag;
  final String imageDigest;
  final ComponentVersion firmwareRunning;
  final ComponentVersion firmwareBundled;

  /// null when either side is unknown.
  final bool? firmwareUpToDate;
  final String firmwareSyncAction;
  final String firmwareSyncError;
  final UpdateStatus update;
  final bool busy;
  final double uptimeS;

  RobotCompatibility get compatibility {
    if (apiVersion < kMinRobotApiVersion) return RobotCompatibility.robotTooOld;
    if (apiVersion > kMaxRobotApiVersion) return RobotCompatibility.appTooOld;
    return RobotCompatibility.compatible;
  }

  static RobotInfo? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RobotInfo.fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  factory RobotInfo.fromJson(Map<String, dynamic> j) {
    final software = _map(j['software']);
    final firmware = _map(j['firmware']);
    final sync = _map(firmware?['sync']);
    return RobotInfo(
      robotId: j['robot_id']?.toString() ?? '',
      apiVersion: (j['api_version'] as num?)?.toInt() ?? 0,
      software: ComponentVersion.fromJson(software),
      imageTag: software?['tag']?.toString() ?? '',
      imageDigest: software?['digest']?.toString() ?? '',
      firmwareRunning: ComponentVersion.fromJson(_map(firmware?['running'])),
      firmwareBundled: ComponentVersion.fromJson(_map(firmware?['bundled'])),
      firmwareUpToDate: firmware?['up_to_date'] is bool
          ? firmware!['up_to_date'] as bool
          : null,
      firmwareSyncAction: sync?['action']?.toString() ?? '',
      firmwareSyncError: sync?['error']?.toString() ?? '',
      update: UpdateStatus.fromJson(_map(j['update'])),
      busy: j['busy'] == true,
      uptimeS: (j['uptime_s'] as num?)?.toDouble() ?? 0,
    );
  }

  static Map<String, dynamic>? _map(dynamic v) =>
      v is Map ? v.cast<String, dynamic>() : null;
}
