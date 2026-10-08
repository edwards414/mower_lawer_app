import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/app_icons.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/recorder_provider.dart';
import 'map_record_bar.dart';
import 'webrtc_camera_view.dart';

/// Manual mode, laid over the map page: the two joysticks, the live front
/// camera and the recording controls. It draws no map of its own (the page
/// underneath stays the one map), and only its controls take touches, so the
/// map still answers everywhere else.
class ManualControlOverlay extends StatefulWidget {
  const ManualControlOverlay({
    super.key,
    required this.mission,
    required this.onExit,
    this.recorder,
  });

  final MissionMockProvider mission;
  final VoidCallback onExit;

  /// Topic (rosbag) recorder; null hides the record button.
  final RecorderProvider? recorder;

  // How far the joysticks sit from the screen's edges, and their size.
  static const double _stickMargin = 18;
  static double _stickSize(Size size) =>
      size.shortestSide < 360 ? 100.0 : 124.0;

  /// How high the joysticks reach above the bottom safe area, plus a gap.
  /// Whatever else sits at the map's bottom edge (its attribution) keeps
  /// above this, out from under a thumb.
  static double controlsClearance(Size size) =>
      _stickMargin + _stickSize(size) + 8;

  @override
  State<ManualControlOverlay> createState() => _ManualControlOverlayState();
}

class _ManualControlOverlayState extends State<ManualControlOverlay>
    with WidgetsBindingObserver {
  static const _publishInterval = Duration(milliseconds: 100);
  // The linear full-deflection speed is the 設定 page's slider
  // (MissionMockProvider.manualLinearSpeed).
  static const _angularSpeed = 0.75;
  static const _deadband = 0.04;
  static const _layoutMotion = Duration(milliseconds: 220);
  // Height of the exit button, the tallest thing in the top-left row.
  static const _exitRow = 44.0;

  Timer? _publishTimer;
  double _linearX = 0.0;
  double _angularZ = 0.0;
  // Read by the status pill alone, so a stick move never rebuilds the page.
  final _moving = ValueNotifier<bool>(false);
  // The camera starts as a small picture-in-picture; a tap enlarges it.
  bool _cameraExpanded = false;
  // The zone / no-go / channel picker is tucked behind one button.
  bool _recordPickerOpen = false;
  int _joystickResetEpoch = 0;

  bool get _hasMotion => _linearX.abs() > 0.001 || _angularZ.abs() > 0.001;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      // Drop both the timer and joystick gesture state. A newly-resumed app
      // must receive a fresh pointer-down before any non-zero velocity can be
      // published again.
      _stopAll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAll(rebuild: false);
    _moving.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    // Follows the mission (can-drive, recording, battery). The map is not in
    // here, so rebuilding on every pose tick stays cheap.
    return ListenableBuilder(
      listenable: widget.mission,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) =>
            _buildControls(constraints.biggest, pad),
      ),
    );
  }

  Widget _buildControls(Size size, EdgeInsets pad) {
    final mission = widget.mission;
    final canDrive = mission.canDriveManually;
    final recording = mission.recordingType != null;
    final pendingSave = mission.hasPendingRecordSave;
    final isPortrait = size.height >= size.width;
    final joystickSize = ManualControlOverlay._stickSize(size);
    final bottom = pad.bottom + ManualControlOverlay._stickMargin;
    // Snackbars float above the joysticks instead of covering them.
    final snackClearance = bottom + joystickSize + 12;
    final topInset = pad.top + 12;
    // Held off the sides a notch or a rounded corner takes (landscape).
    final sideL = math.max(12.0, pad.left);
    final sideR = math.max(12.0, pad.right);

    final camera = _cameraRect(size, topInset, sideR, isPortrait);
    // The recording controls sit under the exit row; in portrait they run the
    // full width, so they also clear the camera.
    final bandTop =
        (isPortrait
            ? math.max(topInset + _exitRow, camera.bottom)
            : topInset + _exitRow) +
        8;
    final recorder = widget.recorder;
    final idle = !recording && !pendingSave;
    final Widget? bar = !idle
        ? MapRecordBar(mission: mission, clearBottom: snackClearance)
        : _recordPickerOpen
        ? _RecordTypeBar(
            enabled: canDrive && !mission.recordCommandPending,
            onPick: (type) => unawaited(_startRecording(type, snackClearance)),
          )
        : null;

    return Stack(
      children: [
        // Camera: a small picture-in-picture; a tap enlarges it.
        AnimatedPositioned.fromRect(
          duration: _layoutMotion,
          curve: Curves.easeInOut,
          rect: camera,
          child: _CameraPane(
            mission: mission,
            expanded: _cameraExpanded,
            banner: isPortrait,
            onTap: () => setState(() => _cameraExpanded = !_cameraExpanded),
          ),
        ),

        // Exit and manual status, top left.
        Positioned(
          top: topInset,
          left: sideL,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _GlassIconButton(
                icon: AppIcons.x,
                tooltip: '退出手動模式',
                onPressed: _exitManual,
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: _moving,
                builder: (context, moving, _) => _ManualStatusPill(
                  connected: canDrive,
                  moving: moving,
                  battery: mission.batteryPercent,
                ),
              ),
            ],
          ),
        ),

        // Recording controls: the boundary picker button and the topic
        // recorder, then the picker, or the REC bar while recording.
        AnimatedPositioned(
          duration: _layoutMotion,
          curve: Curves.easeInOut,
          top: bandTop,
          left: sideL,
          right: isPortrait ? sideR : null,
          width: isPortrait ? null : math.min(size.width * 0.5, 360.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (idle)
                    _RecordPickerButton(
                      open: _recordPickerOpen,
                      onPressed: () => setState(
                        () => _recordPickerOpen = !_recordPickerOpen,
                      ),
                    ),
                  if (idle && recorder != null) const SizedBox(width: 8),
                  if (recorder != null)
                    _BagRecordButton(
                      recorder: recorder,
                      onPressed: () => unawaited(
                        _toggleBagRecording(recorder, snackClearance),
                      ),
                    ),
                ],
              ),
              if (bar != null) ...[const SizedBox(height: 8), bar],
            ],
          ),
        ),

        // Driving controls (bottom corners), each in its own layer so a stick
        // move repaints only itself.
        Positioned(
          left: math.max(ManualControlOverlay._stickMargin, pad.left),
          bottom: bottom,
          child: RepaintBoundary(
            child: _ManualJoystick(
              key: ValueKey('linear-$_joystickResetEpoch'),
              size: joystickSize,
              axis: _JoystickAxis.vertical,
              enabled: canDrive,
              onChanged: _setLinearAxis,
            ),
          ),
        ),
        Positioned(
          right: math.max(ManualControlOverlay._stickMargin, pad.right),
          bottom: bottom,
          child: RepaintBoundary(
            child: _ManualJoystick(
              key: ValueKey('angular-$_joystickResetEpoch'),
              size: joystickSize,
              axis: _JoystickAxis.horizontal,
              enabled: canDrive,
              onChanged: _setAngularAxis,
            ),
          ),
        ),
      ],
    );
  }

  /// The camera's box: a small picture-in-picture at the top right. Enlarged
  /// it is a full-width banner in portrait, a bigger corner view in landscape;
  /// the robot, kept mid-screen by the map, stays in view either way.
  Rect _cameraRect(Size size, double topInset, double sideR, bool isPortrait) {
    if (isPortrait) {
      if (_cameraExpanded) {
        return Rect.fromLTWH(0, 0, size.width, size.height * 0.25);
      }
      final w = math.min(size.width * 0.34, 140.0);
      return Rect.fromLTWH(size.width - sideR - w, topInset, w, w * 9 / 16);
    }
    // Enlarged it stops short of the middle, where the robot is kept.
    final w = _cameraExpanded
        ? math.min(size.width * 0.42, size.width / 2 - 32 - sideR)
        : math.min(size.width * 0.22, 190.0);
    return Rect.fromLTWH(size.width - sideR - w, topInset, w, w * 9 / 16);
  }

  void _setLinearAxis(Offset value) {
    _linearX = _scaleAxis(-value.dy, widget.mission.manualLinearSpeed);
    _publishCurrent();
  }

  void _setAngularAxis(Offset value) {
    _angularZ = _scaleAxis(-value.dx, _angularSpeed);
    _publishCurrent();
  }

  double _scaleAxis(double value, double maxValue) {
    if (value.abs() < _deadband) {
      return 0.0;
    }
    return value.clamp(-1.0, 1.0).toDouble() * maxValue;
  }

  void _publishCurrent() {
    if (!widget.mission.canDriveManually) {
      // The gate closed under a held stick. This event can beat the next timer
      // tick (which would stop it) and cancels that timer, so say stop here
      // rather than leave the last command to run out on the robot's side.
      final wasMoving = _hasMotion;
      _linearX = 0.0;
      _angularZ = 0.0;
      _stopTimer();
      if (wasMoving) widget.mission.stopManualControl();
      _moving.value = false;
      return;
    }
    if (_hasMotion) {
      widget.mission.publishManualVelocity(
        linearX: _linearX,
        angularZ: _angularZ,
      );
      _publishTimer ??= Timer.periodic(_publishInterval, (_) {
        if (!widget.mission.canDriveManually) {
          _stopAll();
          return;
        }
        widget.mission.publishManualVelocity(
          linearX: _linearX,
          angularZ: _angularZ,
        );
      });
    } else {
      _stopTimer();
      widget.mission.stopManualControl();
    }
    _moving.value = _hasMotion;
  }

  void _stopTimer() {
    _publishTimer?.cancel();
    _publishTimer = null;
  }

  void _stopAll({bool rebuild = true}) {
    _linearX = 0.0;
    _angularZ = 0.0;
    _joystickResetEpoch += 1;
    _stopTimer();
    widget.mission.stopManualControl();
    if (mounted && rebuild) {
      _moving.value = false;
      setState(() {});
    }
  }

  Future<void> _startRecording(
    RecordObjectType type,
    double clearBottom,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await widget.mission.startRecording(type);
    if (error != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(error),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, clearBottom),
        ),
      );
    } else if (mounted) {
      setState(() => _recordPickerOpen = false);
    }
  }

  Future<void> _toggleBagRecording(
    RecorderProvider recorder,
    double clearBottom,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = recorder.status.recording
        ? await recorder.stopRecording()
        : await recorder.startRecording();
    messenger.showSnackBar(
      SnackBar(
        content: Text(result.ok ? result.message : '錄製失敗：${result.message}'),
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, clearBottom),
      ),
    );
  }

  /// Leaves manual mode. A recording in progress is kept: its bar on the map
  /// still saves or cancels it.
  void _exitManual() {
    _stopAll();
    widget.onExit();
  }
}

/// The front camera as a picture-in-picture that a tap enlarges, in its own
/// layer so video frames never repaint the rest of the page.
class _CameraPane extends StatelessWidget {
  const _CameraPane({
    required this.mission,
    required this.expanded,
    required this.banner,
    required this.onTap,
  });

  final MissionMockProvider mission;
  final bool expanded;

  /// Enlarged, the view spans the top of the screen (portrait): square at the
  /// top edge, rounded at the bottom.
  final bool banner;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final flush = expanded && banner;
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: flush
                ? const BorderRadius.vertical(bottom: Radius.circular(18))
                : BorderRadius.circular(14),
            boxShadow: flush
                ? null
                : const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 10,
                      offset: Offset(0, 3),
                    ),
                  ],
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              WebrtcCameraView(
                feed: CameraFeed.front,
                whepUrl: mission.whepUrl(CameraFeed.front),
                authHeaders: mission.whepHeaders,
                iceServersUrl: mission.whepIceServersUrl,
                noUrlDetail: mission.cameraUnavailableReason,
                showStats: expanded,
              ),
              Positioned(
                right: 6,
                bottom: 6,
                child: Icon(
                  expanded ? AppIcons.minimize2 : AppIcons.maximize2,
                  color: Colors.white,
                  size: 16,
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Opens the zone / no-go / channel picker. One small button keeps the map
/// clear while driving.
class _RecordPickerButton extends StatelessWidget {
  const _RecordPickerButton({required this.open, required this.onPressed});

  final bool open;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const fg = Color(0xFFE0E0E0);
    return Tooltip(
      message: '記錄工作區、禁入區或通道的邊界',
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  AppIcons.mapPinPen,
                  color: Color(0xFF46D28B),
                  size: 18,
                ),
                const SizedBox(width: 6),
                const Text(
                  '記錄邊界',
                  style: TextStyle(
                    color: fg,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  open ? AppIcons.chevronUp : AppIcons.chevronDown,
                  color: fg,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Topic (rosbag) recording toggle: grey "錄話題" when idle, red REC + elapsed
/// while mower_recorder is running. Driven by /mower_recorder/status.
class _BagRecordButton extends StatelessWidget {
  const _BagRecordButton({required this.recorder, required this.onPressed});

  final RecorderProvider recorder;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: recorder,
      builder: (context, _) {
        final status = recorder.status;
        final pending = recorder.commandPending;
        final recording = status.recording;
        final String label;
        if (pending) {
          label = recording ? '停止中…' : '啟動中…';
        } else if (recording) {
          final mins = (status.elapsedS ~/ 60).toString().padLeft(2, '0');
          final secs = (status.elapsedS.toInt() % 60).toString().padLeft(
            2,
            '0',
          );
          label = 'REC $mins:$secs';
        } else {
          label = '錄話題';
        }
        const red = Color(0xFFE55353);
        final fg = recording ? Colors.white : const Color(0xFFE0E0E0);
        return Tooltip(
          message: recording ? '停止錄製話題' : '開始錄製話題',
          child: Opacity(
            opacity: pending ? 0.6 : 1,
            child: Material(
              color: recording
                  ? red.withValues(alpha: 0.85)
                  : Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(18),
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: pending ? null : onPressed,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        recording ? AppIcons.square : AppIcons.disc,
                        color: recording ? Colors.white : red,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        label,
                        style: TextStyle(
                          color: fg,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pre-record picker: pick what to trace, then drive the perimeter.
class _RecordTypeBar extends StatelessWidget {
  const _RecordTypeBar({required this.enabled, required this.onPick});

  final bool enabled;
  final ValueChanged<RecordObjectType> onPick;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 6),
                child: Text(
                  '開始記錄（開車繞一圈邊界）',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: _RecordChip(
                      icon: AppIcons.squareDashed,
                      label: '工作區',
                      color: const Color(0xFF35B861),
                      onTap: enabled
                          ? () => onPick(RecordObjectType.zone)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RecordChip(
                      icon: AppIcons.ban,
                      label: '禁入區',
                      color: const Color(0xFFE55353),
                      onTap: enabled
                          ? () => onPick(RecordObjectType.risk)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RecordChip(
                      icon: AppIcons.spline,
                      label: '通道',
                      color: const Color(0xFF25AFC6),
                      onTap: enabled
                          ? () => onPick(RecordObjectType.channel)
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecordChip extends StatelessWidget {
  const _RecordChip({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Brighten the icon/text so they read clearly over the (busy) map.
    final fg = Color.lerp(color, Colors.white, 0.32)!;
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.32),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: color.withValues(alpha: 0.95), width: 1.4),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.black.withValues(alpha: 0.5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
    );
  }
}

enum _JoystickAxis { vertical, horizontal }

class _ManualJoystick extends StatefulWidget {
  const _ManualJoystick({
    super.key,
    required this.size,
    required this.axis,
    required this.enabled,
    required this.onChanged,
  });

  final double size;
  final _JoystickAxis axis;
  final bool enabled;
  final ValueChanged<Offset> onChanged;

  @override
  State<_ManualJoystick> createState() => _ManualJoystickState();
}

class _ManualJoystickState extends State<_ManualJoystick> {
  Offset _value = Offset.zero;
  // While a finger is on the stick the knob follows it exactly; the easing
  // only plays on the way back to centre.
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.enabled
        ? const Color(0xFF46D28B)
        : const Color(0xFF90A4AE);
    final radius = widget.size / 2;
    final knobSize = widget.size * 0.42;
    final knobOffset = Offset(
      radius - knobSize / 2 + _value.dx * (radius - knobSize / 2 - 8),
      radius - knobSize / 2 + _value.dy * (radius - knobSize / 2 - 8),
    );

    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.48,
      child: GestureDetector(
        onPanStart: widget.enabled ? _handlePanStart : null,
        onPanUpdate: widget.enabled ? _handlePanUpdate : null,
        onPanEnd: widget.enabled ? (_) => _release() : null,
        onPanCancel: widget.enabled ? _release : null,
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.36),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.36),
                width: 1.4,
              ),
            ),
            child: Stack(
              children: [
                Center(
                  child: Container(
                    width: widget.axis == _JoystickAxis.vertical ? 4 : 62,
                    height: widget.axis == _JoystickAxis.vertical ? 62 : 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: _dragging
                      ? Duration.zero
                      : const Duration(milliseconds: 70),
                  curve: Curves.easeOut,
                  left: knobOffset.dx,
                  top: knobOffset.dy,
                  child: Container(
                    width: knobSize,
                    height: knobSize,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 12,
                          offset: Offset(0, 5),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _handlePanStart(DragStartDetails details) {
    _dragging = true;
    _setFromLocalPosition(details.localPosition);
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    _setFromLocalPosition(details.localPosition);
  }

  void _setFromLocalPosition(Offset local) {
    final center = Offset(widget.size / 2, widget.size / 2);
    var delta = local - center;
    final maxDistance = widget.size / 2 - 18;
    if (delta.distance > maxDistance) {
      delta = Offset.fromDirection(delta.direction, maxDistance);
    }
    var next = Offset(delta.dx / maxDistance, delta.dy / maxDistance);
    next = switch (widget.axis) {
      _JoystickAxis.vertical => Offset(0, next.dy),
      _JoystickAxis.horizontal => Offset(next.dx, 0),
    };
    setState(() => _value = next);
    widget.onChanged(next);
  }

  void _release() {
    setState(() {
      _value = Offset.zero;
      _dragging = false;
    });
    widget.onChanged(Offset.zero);
  }
}

class _ManualStatusPill extends StatelessWidget {
  const _ManualStatusPill({
    required this.connected,
    required this.moving,
    this.battery,
  });

  final bool connected;
  final bool moving;

  /// Battery percent, when known: still worth seeing while driving.
  final double? battery;

  @override
  Widget build(BuildContext context) {
    final label = connected
        ? moving
              ? '手動輸出中'
              : '手動待命'
        : '機器人未就緒';
    final color = connected ? const Color(0xFF46D28B) : const Color(0xFFFFC857);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              connected ? AppIcons.circleDot : AppIcons.wifiOff,
              color: color,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (battery != null) ...[
              const SizedBox(width: 8),
              Text(
                '${battery!.round()}%',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
