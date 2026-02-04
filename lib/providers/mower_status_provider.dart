import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/coverage_path.dart';
import '../models/mower_status.dart';
import '../utils/constants.dart';
import '../services/ros_service.dart';

/// 割草机状态 Provider：轮询 ROS 并通知监听者
class MowerStatusProvider extends ChangeNotifier {
  MowerStatusProvider(this._ros) {
    _fetch();
    _timer = Timer.periodic(
      const Duration(milliseconds: AppConstants.statusPollIntervalMs),
      (_) => _fetch(),
    );
  }

  final RosService _ros;
  Timer? _timer;
  MowerStatus? _status;
  CoveragePath? _coveragePath;

  MowerStatus? get status => _status;
  CoveragePath? get coveragePath => _coveragePath;

  Future<void> startMowing() => _ros.startMowing();
  Future<void> stopMowing() => _ros.stopMowing();
  bool get isMowing => _ros.isMowing;

  Future<void> _fetch() async {
    final s = await _ros.getMowerStatus();
    final c = await _ros.getCoveragePath();
    _status = s;
    _coveragePath = c;
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
