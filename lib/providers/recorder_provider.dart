import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../services/rosbridge_service.dart';

/// Live recording state, from /mower_recorder/status.
class RecordingStatus {
  const RecordingStatus({
    this.recording = false,
    this.runId,
    this.elapsedS = 0,
    this.bagBytes = 0,
    this.numTopics = 0,
  });

  final bool recording;
  final String? runId;
  final double elapsedS;
  final int bagBytes;
  final int numTopics;

  factory RecordingStatus.fromJson(Map<String, dynamic> j) => RecordingStatus(
    recording: j['recording'] == true,
    runId: j['run_id'] as String?,
    elapsedS: (j['elapsed_s'] as num?)?.toDouble() ?? 0,
    bagBytes: (j['bag_bytes'] as num?)?.toInt() ?? 0,
    numTopics: (j['num_topics'] as num?)?.toInt() ?? 0,
  );
}

/// One recorded run, from the /mower_recorder/bags list.
class BagInfo {
  const BagInfo({
    required this.runId,
    required this.displayName,
    required this.sizeBytes,
    required this.uploaded,
    required this.uploading,
    required this.recording,
    this.startTime = '',
  });

  final String runId;
  final String displayName;
  final int sizeBytes;
  final bool uploaded;
  final bool uploading;
  final bool recording;
  final String startTime;

  factory BagInfo.fromJson(Map<String, dynamic> j) => BagInfo(
    runId: j['run_id']?.toString() ?? '',
    displayName: j['display_name']?.toString() ?? j['run_id']?.toString() ?? '',
    sizeBytes: (j['size_bytes'] as num?)?.toInt() ?? 0,
    uploaded: j['uploaded'] == true,
    uploading: j['uploading'] == true,
    recording: j['recording'] == true,
    startTime: j['start_time']?.toString() ?? '',
  );
}

/// Drives the on-robot mower_recorder over rosbridge:
///  - subscribes /mower_recorder/status  (recording banner)
///  - subscribes /mower_recorder/bags    (the list + network/R2 state)
///  - publishes  /mower_recorder/command (refresh/rename/delete/upload_now)
///  - listens    /mower_recorder/command_result (toast text)
class RecorderProvider extends ChangeNotifier {
  RecorderProvider({required RosbridgeService rosbridge})
    : _rosbridge = rosbridge {
    _init();
  }

  final RosbridgeService _rosbridge;
  StreamSubscription<RosbridgeTopicMessage>? _sub;

  static const _statusTopic = '/mower_recorder/status';
  static const _bagsTopic = '/mower_recorder/bags';
  static const _commandTopic = '/mower_recorder/command';
  static const _resultTopic = '/mower_recorder/command_result';
  static const _latchedQos = {
    'durability': 'transient_local',
    'reliability': 'reliable',
  };

  RecordingStatus _status = const RecordingStatus();
  List<BagInfo> _bags = const [];
  bool _networkOk = false;
  bool _r2Configured = false;
  String? _lastResult;
  int _cmdSeq = 0;

  RecordingStatus get status => _status;
  List<BagInfo> get bags => _bags;
  bool get networkOk => _networkOk;
  bool get r2Configured => _r2Configured;
  String? get lastResult => _lastResult;

  void _init() {
    _rosbridge.subscribe(
      _statusTopic,
      type: 'std_msgs/msg/String',
      qos: _latchedQos,
    );
    _rosbridge.subscribe(
      _bagsTopic,
      type: 'std_msgs/msg/String',
      qos: _latchedQos,
    );
    _rosbridge.subscribe(_resultTopic, type: 'std_msgs/msg/String');
    _sub = _rosbridge.messages.listen(_onMessage);
    _rosbridge.connect();
  }

  void _onMessage(RosbridgeTopicMessage event) {
    final raw = event.message['data'];
    if (raw is! String) {
      return;
    }
    final Map<String, dynamic> data;
    try {
      data = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    switch (event.topic) {
      case _statusTopic:
        _status = RecordingStatus.fromJson(data);
        notifyListeners();
        break;
      case _bagsTopic:
        _networkOk = data['network_ok'] == true;
        _r2Configured = data['r2_configured'] == true;
        _bags = ((data['bags'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => BagInfo.fromJson(e.cast<String, dynamic>()))
            .toList();
        notifyListeners();
        break;
      case _resultTopic:
        _lastResult = data['message']?.toString();
        notifyListeners();
        break;
    }
  }

  void _send(Map<String, dynamic> cmd) {
    cmd['req_id'] = 'app_${DateTime.now().millisecondsSinceEpoch}_${_cmdSeq++}';
    _rosbridge.publish(
      _commandTopic,
      type: 'std_msgs/msg/String',
      message: {'data': jsonEncode(cmd)},
    );
  }

  void refresh() => _send({'action': 'refresh'});

  void rename(String runId, String newName) =>
      _send({'action': 'rename', 'run_id': runId, 'new_name': newName});

  void delete(String runId) => _send({'action': 'delete', 'run_id': runId});

  void uploadNow() => _send({'action': 'upload_now'});

  @override
  void dispose() {
    _sub?.cancel();
    _rosbridge.unsubscribe(_statusTopic);
    _rosbridge.unsubscribe(_bagsTopic);
    _rosbridge.unsubscribe(_resultTopic);
    super.dispose();
  }
}
