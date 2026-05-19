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

  bool get _moving => _linearX.abs() > 0.001 || _angularZ.abs() > 0.001;

  @override
  void dispose() {
    _stopAll(rebuild: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final canDrive = widget.mission.rosConnected;
    final joystickSize = media.size.width < 360 ? 112.0 : 132.0;
    final miniMapSize = math.min(
      math.max(media.size.width * 0.34, 132.0),
      190.0,
    );
    final bottom = media.padding.bottom + 22.0;
    final activeFrame = widget.mission.cameraFrame(widget.cameraFeed);
    final error = widget.mission.cameraError(widget.cameraFeed);

    return Stack(
      children: [
        Positioned.fill(
          child: _CameraStage(
            feed: widget.cameraFeed,
            topic: widget.mission.cameraTopic(widget.cameraFeed),
            frame: activeFrame,
            error: error,
            connected: widget.mission.rosConnected,
          ),
        ),
        Positioned(
          top: media.padding.top + 12,
          left: 12,
          child: Row(
            children: [
              _GlassIconButton(
                icon: Icons.close,
                tooltip: '退出手動',
                onPressed: _exitManual,
              ),
              const SizedBox(width: 8),
              _CameraFeedToggle(
                value: widget.cameraFeed,
                onChanged: widget.onCameraFeedChanged,
              ),
            ],
          ),
        ),
        Positioned(
          top: media.padding.top + 12,
          right: 12,
          width: miniMapSize,
          height: miniMapSize,
          child: _MiniMap(mission: widget.mission),
        ),
        Positioned(
          left: 18,
          bottom: bottom,
          child: _ManualJoystick(
            size: joystickSize,
            axis: _JoystickAxis.vertical,
            label: '線速',
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
            label: '角速',
            enabled: canDrive,
            onChanged: _setAngularAxis,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: bottom + joystickSize * 0.34,
          child: Center(
            child: FilledButton.icon(
              onPressed: _stopAll,
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('停止'),
            ),
          ),
        ),
        Positioned(
          left: 16,
          right: 16,
          bottom: bottom + joystickSize + 14,
          child: _ManualStatusPill(
            connected: widget.mission.rosConnected,
            moving: _moving,
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
    _stopAll();
    widget.onExit();
  }
}

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

class _MiniMap extends StatelessWidget {
  const _MiniMap({required this.mission});

  final MissionMockProvider mission;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x55000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(17),
        child: MissionMapCanvas(
          mission: mission,
          bottomInset: 0,
          showScalePill: false,
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
    required this.label,
    required this.enabled,
    required this.onChanged,
  });

  final double size;
  final _JoystickAxis axis;
  final String label;
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
            ),
          ),
          const SizedBox(height: 8),
          GestureDetector(
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
        ],
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
    return Center(
      child: DecoratedBox(
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
      ),
    );
  }
}
