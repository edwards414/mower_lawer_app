import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import 'mission_map_canvas.dart';

class ManualControlOverlay extends StatefulWidget {
  const ManualControlOverlay({
    super.key,
    required this.mission,
    required this.cameraFeed,
    required this.onCameraFeedChanged,
    required this.onExit,
  });

  final MissionMockProvider mission;
  final CameraFeed cameraFeed;
  final ValueChanged<CameraFeed> onCameraFeedChanged;
  final VoidCallback onExit;

  @override
  State<ManualControlOverlay> createState() => _ManualControlOverlayState();
}

class _ManualControlOverlayState extends State<ManualControlOverlay> {
  static const _publishInterval = Duration(milliseconds: 100);
  static const _linearSpeed = 0.22;
  static const _angularSpeed = 0.75;
  static const _deadband = 0.04;

  Timer? _publishTimer;
  double _linearX = 0.0;
  double _angularZ = 0.0;
  // Landscape only: front/rear toggle + record chips are tucked into one
  // expandable button to keep the split view clean.
  bool _controlsExpanded = false;

  bool get _moving => _linearX.abs() > 0.001 || _angularZ.abs() > 0.001;

  @override
  void dispose() {
    _stopAll(rebuild: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final mission = widget.mission;
    final canDrive = mission.rosConnected;
    final recording = mission.recordingType != null;
    final isPortrait = media.orientation == Orientation.portrait;
    final size = media.size;
    final joystickSize = size.shortestSide < 360 ? 100.0 : 124.0;
    final bottom = media.padding.bottom + 18.0;
    final topInset = media.padding.top + 12;

    final cameraStage = _CameraStage(
      feed: widget.cameraFeed,
      topic: mission.cameraTopic(widget.cameraFeed),
      frame: mission.cameraFrame(widget.cameraFeed),
      error: mission.cameraError(widget.cameraFeed),
      connected: mission.rosConnected,
    );
    final mapStage = MissionMapCanvas(
      mission: mission,
      // Full-bleed: the map fills its panel; the joysticks just overlay it.
      bottomInset: 0,
      showScalePill: false,
    );

    // Always show BOTH camera and map. Portrait: camera band on top (1/4),
    // map fills the rest. Landscape: map left 1/3, camera right 2/3.
    final cameraBand = isPortrait ? size.height * 0.25 : 0.0;
    final Widget base = isPortrait
        ? Column(
            children: [
              SizedBox(
                height: cameraBand,
                width: double.infinity,
                child: cameraStage,
              ),
              Expanded(child: mapStage),
            ],
          )
        : Row(
            children: [
              SizedBox(width: size.width / 3, child: mapStage),
              Expanded(child: cameraStage),
            ],
          );

    final cameraToggle = _CameraFeedToggle(
      value: widget.cameraFeed,
      onChanged: widget.onCameraFeedChanged,
    );
    final recordHud = _RecordHud(
      mission: mission,
      onSave: () => mission.stopRecording(save: true),
      onCancel: () => mission.stopRecording(save: false),
    );
    final typeBar = _RecordTypeBar(
      enabled: canDrive,
      onPick: mission.startRecording,
    );

    return Stack(
      children: [
        Positioned.fill(child: base),

        // Exit (always top-left).
        Positioned(
          top: topInset,
          left: 12,
          child: _GlassIconButton(
            icon: Icons.close,
            tooltip: '退出手動',
            onPressed: _exitManual,
          ),
        ),

        // ── Manual-drive status pill, top-right in both orientations.
        Positioned(
          top: topInset,
          right: 12,
          child: _ManualStatusPill(
            connected: mission.rosConnected,
            moving: _moving,
          ),
        ),

        // ── Orientation-specific control band.
        if (isPortrait) ...[
          // Front/rear toggle sits next to the exit button on the camera band.
          Positioned(top: topInset, left: 64, child: cameraToggle),
          // Record band (chips → REC HUD) at the top of the map area.
          Positioned(
            top: cameraBand + 10,
            left: 12,
            right: 12,
            child: recording ? recordHud : typeBar,
          ),
        ] else if (recording) ...[
          // Landscape recording: REC HUD as a left panel (top-right is the
          // status pill); no expandable button while recording.
          Positioned(
            top: topInset,
            left: 64,
            width: math.min(size.width * 0.5, 360.0),
            child: recordHud,
          ),
        ] else ...[
          // Landscape idle: tuck the toggle + chips into one expandable button.
          Positioned(
            top: topInset,
            left: 64,
            child: _GlassIconButton(
              icon: _controlsExpanded ? Icons.expand_less : Icons.tune,
              tooltip: '切換功能',
              onPressed: () =>
                  setState(() => _controlsExpanded = !_controlsExpanded),
            ),
          ),
          if (_controlsExpanded)
            Positioned(
              top: topInset + 52,
              left: 12,
              width: math.min(size.width * 0.5, 320.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  cameraToggle,
                  const SizedBox(height: 8),
                  typeBar,
                ],
              ),
            ),
        ],

        // ── Driving controls (bottom corners), shared by both orientations.
        Positioned(
          left: 18,
          bottom: bottom,
          child: _ManualJoystick(
            size: joystickSize,
            axis: _JoystickAxis.vertical,
            enabled: canDrive,
            onChanged: _setLinearAxis,
          ),
        ),
        Positioned(
          right: 18,
          bottom: bottom,
          child: _ManualJoystick(
            size: joystickSize,
            axis: _JoystickAxis.horizontal,
            enabled: canDrive,
            onChanged: _setAngularAxis,
          ),
        ),
      ],
    );
  }

  void _setLinearAxis(Offset value) {
    _linearX = _scaleAxis(-value.dy, _linearSpeed);
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
    if (!widget.mission.rosConnected) {
      _stopTimer();
      return;
    }
    if (_moving) {
      widget.mission.publishManualVelocity(
        linearX: _linearX,
        angularZ: _angularZ,
      );
      _publishTimer ??= Timer.periodic(_publishInterval, (_) {
        widget.mission.publishManualVelocity(
          linearX: _linearX,
          angularZ: _angularZ,
        );
      });
    } else {
      _stopTimer();
      widget.mission.stopManualControl();
    }
    setState(() {});
  }

  void _stopTimer() {
    _publishTimer?.cancel();
    _publishTimer = null;
  }

  void _stopAll({bool rebuild = true}) {
    _linearX = 0.0;
    _angularZ = 0.0;
    _stopTimer();
    widget.mission.stopManualControl();
    if (mounted && rebuild) {
      setState(() {});
    }
  }

  void _exitManual() {
    if (widget.mission.recordingType != null) {
      widget.mission.stopRecording(save: false);
    }
    _stopAll();
    widget.onExit();
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
                      icon: Icons.crop_square,
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
                      icon: Icons.dangerous_outlined,
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
                      icon: Icons.timeline,
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

/// Live recording HUD: type, elapsed, point count, and finish/cancel.
class _RecordHud extends StatelessWidget {
  const _RecordHud({
    required this.mission,
    required this.onSave,
    required this.onCancel,
  });

  final MissionMockProvider mission;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final elapsed = mission.recordingElapsed;
    final minutes = elapsed.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(
              Icons.fiber_manual_record,
              color: Color(0xFFE55353),
              size: 16,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${mission.recordingTitle} · $minutes:$seconds · '
                '${mission.recordPointCount} 點',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _HudButton(
              icon: Icons.check,
              label: '存',
              color: const Color(0xFF35B861),
              onTap: onSave,
            ),
            const SizedBox(width: 6),
            _HudButton(
              icon: Icons.close,
              label: '取消',
              color: const Color(0xFF90A4AE),
              onTap: onCancel,
            ),
          ],
        ),
      ),
    );
  }
}

class _HudButton extends StatelessWidget {
  const _HudButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 15),
            const SizedBox(width: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Rounded, bordered frame used for the shrunk camera while recording.
class _CameraStage extends StatelessWidget {
  const _CameraStage({
    required this.feed,
    required this.topic,
    required this.frame,
    required this.error,
    required this.connected,
  });

  final CameraFeed feed;
  final String topic;
  final CameraFrame? frame;
  final String? error;
  final bool connected;

  @override
  Widget build(BuildContext context) {
    final frame = this.frame;
    if (frame != null) {
      return Stack(
        fit: StackFit.expand,
        children: [
          RawImage(image: frame.image, fit: BoxFit.cover),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x66000000),
                  Color(0x00000000),
                  Color(0x66000000),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final title = feed == CameraFeed.front ? '前鏡頭' : '後鏡頭';
    final detail = error ?? (connected ? '等待 $topic' : '等待 rosbridge');
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF111827)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Color(0xFFECEFF1),
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB0BEC5),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraFeedToggle extends StatelessWidget {
  const _CameraFeedToggle({required this.value, required this.onChanged});

  final CameraFeed value;
  final ValueChanged<CameraFeed> onChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FeedButton(
              label: '前',
              selected: value == CameraFeed.front,
              onTap: () => onChanged(CameraFeed.front),
            ),
            _FeedButton(
              label: '後',
              selected: value == CameraFeed.rear,
              onTap: () => onChanged(CameraFeed.rear),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedButton extends StatelessWidget {
  const _FeedButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 38,
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF111827) : Colors.white,
            fontWeight: FontWeight.w900,
          ),
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
                      duration: const Duration(milliseconds: 70),
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
    setState(() => _value = Offset.zero);
    widget.onChanged(Offset.zero);
  }
}

class _ManualStatusPill extends StatelessWidget {
  const _ManualStatusPill({required this.connected, required this.moving});

  final bool connected;
  final bool moving;

  @override
  Widget build(BuildContext context) {
    final label = connected
        ? moving
              ? '手動輸出中'
              : '手動待命'
        : 'rosbridge 未連線';
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
              connected
                  ? Icons.radio_button_checked
                  : Icons.portable_wifi_off_outlined,
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
          ],
        ),
      ),
    );
  }
}
