import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';

import '../providers/mission_mock_provider.dart';
import '../services/screen_wake.dart';

/// The joysticks, always on the map page: left for forward / back, right for
/// turning, 定速 between them. With 單搖桿 chosen on the 設定 page
/// ([MissionMockProvider.manualSingleStick]) there is one stick, in the middle
/// of the bottom edge, that does both. There is no manual mode to enter. While the
/// robot cannot be driven the sticks stay where they are, locked, with the
/// reason written on them; tapping a locked stick asks [onLockedTap] what to
/// do (during mowing: the way to stop the task). It draws no map of its own
/// and only the sticks take touches, so the map still answers everywhere else.
class ManualControlOverlay extends StatefulWidget {
  const ManualControlOverlay({
    super.key,
    required this.mission,
    this.bottomInset = 0,
    this.hidden = false,
    this.onLockedTap,
    this.onMovingChanged,
    this.screenWake = const PlatformScreenWake(),
  });

  final MissionMockProvider mission;

  /// Room left free under the sticks.
  final double bottomInset;

  /// Takes the sticks off the map (the page is not shown, a drawing tool is
  /// in use). Hiding them stops the robot first.
  final bool hidden;

  /// A locked stick was tapped; given [MissionMockProvider.manualDriveBlockReason].
  final ValueChanged<String>? onLockedTap;

  /// Whether the sticks are sending motion: the page keeps the robot in view
  /// and the map still while they do.
  final ValueChanged<bool>? onMovingChanged;

  /// Holds the screen on while cruising (定速), and only then.
  final ScreenWake screenWake;

  // How far the joysticks sit from the screen's edges, and their size.
  static const double _stickMargin = 18;
  static double _stickSize(Size size) =>
      size.shortestSide < 360 ? 100.0 : 124.0;

  /// The gap between the bottom of the map and the bottom of the sticks.
  static const double stickGap = 14;

  /// The caption pill over each stick, with its gap.
  static const double _captionExtent = 26;

  /// How high the joysticks (with their captions) reach above [bottomInset],
  /// plus a gap. Whatever else sits at the map's bottom edge keeps above
  /// this, out from under a thumb.
  static double controlsClearance(Size size) =>
      stickGap + _stickSize(size) + _captionExtent + 8;

  @override
  State<ManualControlOverlay> createState() => ManualControlOverlayState();
}

class ManualControlOverlayState extends State<ManualControlOverlay>
    with WidgetsBindingObserver {
  static const _publishInterval = Duration(milliseconds: 100);
  // The linear full-deflection speed is the 設定 page's slider
  // (MissionMockProvider.manualLinearSpeed).
  static const _angularSpeed = 0.75;
  static const _deadband = 0.04;
  // One stick carries both axes, so a push straight ahead always has a little
  // sideways in it: each axis starts later, and grows from zero from there.
  static const _singleDeadband = 0.15;
  // Cruising on one stick, pulling it back this far ends the cruise.
  static const _singleCruiseBrake = 0.5;
  // The 定速 button, and its gap to the right stick.
  static const _cruiseSize = 56.0;
  static const _cruiseGap = 12.0;

  Timer? _publishTimer;
  double _linearX = 0.0;
  double _angularZ = 0.0;
  // Read by the status pill alone, so a stick move never rebuilds the page.
  final _moving = ValueNotifier<bool>(false);
  // Cruise (定速): the locked forward speed in m/s, or null. While it is set,
  // _linearX holds it and the left stick no longer writes there. Read by the
  // pill and the 定速 button alone, like _moving.
  final _cruise = ValueNotifier<double?>(null);
  late final _pillState = Listenable.merge([_moving, _cruise]);
  // Whether this overlay asked for the screen to stay on.
  bool _screenKeptOn = false;
  int _joystickResetEpoch = 0;
  // The layout the sticks were last built for (one stick or two).
  late bool _single;
  // The one stick was pulled back to end a cruise: it stays a brake, not
  // reverse, until it comes back to the middle.
  bool _singleBraking = false;

  bool get _hasMotion => _linearX.abs() > 0.001 || _angularZ.abs() > 0.001;
  bool get _cruising => _cruise.value != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _moving.addListener(_reportMoving);
    _single = widget.mission.manualSingleStick;
    widget.mission.addListener(_onMissionChanged);
  }

  void _reportMoving() => widget.onMovingChanged?.call(_moving.value);

  /// Changing between one stick and two stops the robot first: the sticks on
  /// screen are replaced, and a held one must be touched again.
  void _onMissionChanged() {
    final single = widget.mission.manualSingleStick;
    if (single == _single) return;
    _single = single;
    // Nothing held (the usual case: the pick is made on another tab, or is
    // the saved one loading at start): no stop to send.
    if (_hasMotion || _cruising) _stopAll();
  }

  @override
  void didUpdateWidget(ManualControlOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mission != oldWidget.mission) {
      oldWidget.mission.removeListener(_onMissionChanged);
      widget.mission.addListener(_onMissionChanged);
      _onMissionChanged();
    }
    // Whatever takes the sticks away stops the robot first; a finger still
    // on a stick has to come off and touch again.
    if (widget.hidden && !oldWidget.hidden) {
      _stopAll(rebuild: false);
      _moving.value = false;
    }
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
    widget.mission.removeListener(_onMissionChanged);
    _stopAll(rebuild: false);
    _moving.removeListener(_reportMoving);
    _moving.dispose();
    _cruise.dispose();
    super.dispose();
  }

  /// Stops the robot and drops the sticks back to centre. The page calls it
  /// before anything covers the sticks (a sheet, a dialog), since a finger
  /// held on a stick would otherwise keep driving underneath.
  void halt() => _stopAll();

  @override
  Widget build(BuildContext context) {
    if (widget.hidden) return const SizedBox.shrink();
    final pad = MediaQuery.paddingOf(context);
    // Follows the mission (can-drive, lock reason). The map is not in here,
    // so rebuilding on every pose tick stays cheap.
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
    final lockReason = mission.manualDriveBlockReason;
    final joystickSize = ManualControlOverlay._stickSize(size);
    final bottom = widget.bottomInset + ManualControlOverlay.stickGap;
    // Snackbars float above the joysticks instead of covering them.
    final snackClearance = bottom + joystickSize + 12;
    final stickLeft = math.max(ManualControlOverlay._stickMargin, pad.left);
    final stickRight = math.max(ManualControlOverlay._stickMargin, pad.right);
    final lockLabel = lockReason == null
        ? null
        : mission.manualDriveLockedByMission
        ? '$lockReason\n點一下看選項'
        : lockReason;

    final single = mission.manualSingleStick;

    Widget stick(_JoystickAxis axis, String caption) {
      final linear = axis != _JoystickAxis.horizontal;
      return RepaintBoundary(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // On a pill of its own: the map under it may be light or dark.
            DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(999),
                boxShadow: AppStyle.floatShadow,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                child: Text(
                  caption,
                  style: const TextStyle(
                    color: AppStyle.ink,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Stack(
              children: [
                _ManualJoystick(
                  key: ValueKey('${axis.name}-$_joystickResetEpoch'),
                  size: joystickSize,
                  axis: axis,
                  enabled: canDrive,
                  onStart: linear ? _onLinearStickTouched : null,
                  onChanged: switch (axis) {
                    _JoystickAxis.vertical => _setLinearAxis,
                    _JoystickAxis.horizontal => _setAngularAxis,
                    _JoystickAxis.both => _setBothAxes,
                  },
                ),
                if (lockLabel != null)
                  Positioned.fill(
                    child: _StickLock(
                      label: lockLabel,
                      onTap: widget.onLockedTap == null
                          ? null
                          : () => widget.onLockedTap!(lockReason!),
                    ),
                  ),
              ],
            ),
          ],
        ),
      );
    }

    return Stack(
      children: [
        // What the sticks are doing, while they do something.
        Positioned(
          left: 0,
          right: 0,
          bottom:
              bottom + joystickSize + ManualControlOverlay._captionExtent + 8,
          child: IgnorePointer(
            child: Center(
              child: ListenableBuilder(
                listenable: _pillState,
                builder: (context, _) => _moving.value || _cruising
                    ? _ManualStatusPill(
                        connected: canDrive,
                        moving: _moving.value,
                        cruiseSpeed: _cruise.value,
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        // Driving controls (bottom corners), each in its own layer so a stick
        // move repaints only itself.
        if (!single)
          Positioned(
            left: stickLeft,
            bottom: bottom,
            child: stick(_JoystickAxis.vertical, '前進 / 後退'),
          ),
        if (single)
          // The one stick: in the middle of the bottom edge.
          Positioned(
            left: (size.width - joystickSize) / 2,
            bottom: bottom,
            child: stick(_JoystickAxis.both, '行駛'),
          )
        else
          Positioned(
            right: stickRight,
            bottom: bottom,
            child: stick(_JoystickAxis.horizontal, '轉向'),
          ),
        // Cruise (定速), just inside the right stick: the right thumb reaches
        // it while the left one holds the stick forward. With one stick it
        // sits right beside it, for the other hand's thumb.
        if (lockReason == null || _cruising)
          Positioned(
            right: single
                ? (size.width - joystickSize) / 2 - _cruiseGap - _cruiseSize
                : stickRight + joystickSize + _cruiseGap,
            bottom: bottom + (joystickSize - _cruiseSize) / 2,
            child: RepaintBoundary(
              child: ValueListenableBuilder<double?>(
                valueListenable: _cruise,
                builder: (context, speed, _) => _CruiseButton(
                  size: _cruiseSize,
                  single: single,
                  cruising: speed != null,
                  // Cancelling is never blocked.
                  enabled: canDrive || speed != null,
                  onPressed: () => _toggleCruise(snackClearance),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _setLinearAxis(Offset value) {
    // Cruising, the touch that set the speed may still be on the stick: its
    // moves and its release leave the locked speed alone. Only a new touch
    // ends the cruise (_onLinearStickTouched).
    if (_cruising) return;
    _linearX = _scaleAxis(-value.dy, widget.mission.manualLinearSpeed);
    _publishCurrent();
  }

  /// The one stick (單搖桿): forward / back and turning together. Cruising,
  /// it only steers, so a new touch does not end the cruise the way the left
  /// stick's does; pulling it well back does (and 定速 again, as always).
  void _setBothAxes(Offset value) {
    _angularZ = _scaleSingleAxis(-value.dx, _angularSpeed);
    if (value.dy.abs() < _singleDeadband) _singleBraking = false;
    if (_cruising) {
      if (value.dy >= _singleCruiseBrake) {
        // Stops going forward; what the stick turns stays.
        _singleBraking = true;
        _cancelCruise();
        return;
      }
    } else if (_singleBraking) {
      _linearX = 0.0;
    } else {
      _linearX = _scaleSingleAxis(-value.dy, widget.mission.manualLinearSpeed);
    }
    _publishCurrent();
  }

  /// A new touch on the left stick takes the speed back: the cruise ends with
  /// a stop, and from there the stick drives as usual. The one stick steers
  /// the cruise instead (see [_setBothAxes]).
  void _onLinearStickTouched() {
    if (_cruising && !_single) _cancelCruise();
  }

  /// The 定速 button: locks the forward speed the left stick holds right now,
  /// or ends the cruise.
  void _toggleCruise(double clearBottom) {
    if (_cruising) {
      _cancelCruise();
      return;
    }
    if (!widget.mission.canDriveManually) return;
    // Forward only: past the deadband, never in reverse.
    if (_linearX <= 0.001) {
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(_single ? '先把搖桿往前推，再按定速' : '先把左搖桿往前推，再按定速'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            margin: EdgeInsets.fromLTRB(16, 0, 16, clearBottom),
          ),
        );
      return;
    }
    // The publish timer is already running for the held stick; from here it
    // sends this speed until something ends the cruise.
    _cruise.value = _linearX;
    _keepScreenOn(true);
  }

  /// Ends the cruise and stops the way a released left stick does: linear goes
  /// to zero (a held right stick keeps turning), and stop is sent.
  void _cancelCruise() {
    _endCruise();
    if (!widget.mission.canDriveManually) {
      // The gate closed before the timer saw it: stop outright, as its tick
      // would have.
      _stopAll();
      return;
    }
    _linearX = 0.0;
    _publishCurrent();
  }

  /// Clears the cruise and lets the screen sleep again. The caller zeroes the
  /// speed and says stop.
  void _endCruise() {
    _cruise.value = null;
    _keepScreenOn(false);
  }

  void _keepScreenOn(bool on) {
    if (_screenKeptOn == on) return;
    _screenKeptOn = on;
    unawaited(widget.screenWake.keepOn(on));
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

  /// [_scaleAxis] for the one stick: a wider deadband, and the rest of the
  /// travel stretched over the full range so the speed starts from zero.
  double _scaleSingleAxis(double value, double maxValue) {
    final travel = value.abs();
    if (travel < _singleDeadband) {
      return 0.0;
    }
    final scaled = ((travel - _singleDeadband) / (1 - _singleDeadband)).clamp(
      0.0,
      1.0,
    );
    return value.sign * scaled * maxValue;
  }

  void _publishCurrent() {
    if (!widget.mission.canDriveManually) {
      // The gate closed under a held stick. This event can beat the next timer
      // tick (which would stop it) and cancels that timer, so say stop here
      // rather than leave the last command to run out on the robot's side.
      final wasMoving = _hasMotion;
      _endCruise();
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

  /// Every way out of driving (backgrounding, the gate closing, the sticks
  /// hidden or covered, dispose) lands here, so each one also ends a cruise.
  void _stopAll({bool rebuild = true}) {
    _endCruise();
    _singleBraking = false;
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
}

/// Covers a locked stick: a lock and the reason, right where the thumb goes.
class _StickLock extends StatelessWidget {
  const _StickLock({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // A frosted cover over the stick: readable on any map.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.86),
          boxShadow: AppStyle.floatShadow,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(AppIcons.lock, color: AppStyle.muted, size: 20),
              const SizedBox(height: 4),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppStyle.ink,
                  fontSize: 12,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _JoystickAxis { vertical, horizontal, both }

class _ManualJoystick extends StatefulWidget {
  const _ManualJoystick({
    super.key,
    required this.size,
    required this.axis,
    required this.enabled,
    required this.onChanged,
    this.onStart,
  });

  final double size;
  final _JoystickAxis axis;
  final bool enabled;
  final ValueChanged<Offset> onChanged;

  /// A new touch begins, before its first [onChanged].
  final VoidCallback? onStart;

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
          // Frosted white base, green knob: the home page's colours.
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.42),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.9),
                width: 1.5,
              ),
              boxShadow: AppStyle.floatShadow,
            ),
            child: Stack(
              children: [
                // The way the stick moves: a bar, or a cross for both.
                if (widget.axis != _JoystickAxis.horizontal)
                  Center(child: _guideBar(width: 4, height: 62)),
                if (widget.axis != _JoystickAxis.vertical)
                  Center(child: _guideBar(width: 62, height: 4)),
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
                      color: widget.enabled ? null : const Color(0xFFB0BEC5),
                      gradient: widget.enabled ? AppStyle.heroGradient : null,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: AppStyle.glow(
                        widget.enabled ? AppStyle.green : Colors.black,
                      ),
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

  Widget _guideBar({required double width, required double height}) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppStyle.ink.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  void _handlePanStart(DragStartDetails details) {
    widget.onStart?.call();
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
      _JoystickAxis.both => next,
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

/// Cruise (定速): locks the forward speed the stick holds. Lit while cruising,
/// when a press ends it.
class _CruiseButton extends StatelessWidget {
  const _CruiseButton({
    required this.size,
    required this.single,
    required this.cruising,
    required this.enabled,
    required this.onPressed,
  });

  final double size;

  /// One stick on the page, not two.
  final bool single;
  final bool cruising;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // White like the map's buttons; green (the home page's gradient) while
    // cruising.
    final radius = BorderRadius.circular(18);
    return Tooltip(
      message: cruising
          ? '取消定速'
          : single
          ? '定速：鎖定搖桿目前的前進速度'
          : '定速：鎖定左搖桿目前的前進速度',
      child: Opacity(
        opacity: enabled ? 1.0 : 0.48,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            color: cruising ? null : Colors.white,
            gradient: cruising ? AppStyle.heroGradient : null,
            boxShadow: cruising
                ? AppStyle.glow(AppStyle.green)
                : AppStyle.floatShadow,
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: radius,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled ? onPressed : null,
              child: SizedBox.square(
                dimension: size,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      AppIcons.gauge,
                      color: cruising ? AppStyle.lime : AppStyle.green,
                      size: 22,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '定速',
                      style: TextStyle(
                        color: cruising ? Colors.white : AppStyle.ink,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualStatusPill extends StatelessWidget {
  const _ManualStatusPill({
    required this.connected,
    required this.moving,
    this.cruiseSpeed,
  });

  final bool connected;
  final bool moving;

  /// The locked speed while cruising (定速), in m/s.
  final double? cruiseSpeed;

  @override
  Widget build(BuildContext context) {
    final cruise = connected ? cruiseSpeed : null;
    final label = connected
        ? cruise != null
              ? '定速 ${cruise.toStringAsFixed(2)} m/s'
              : moving
              ? '手動輸出中'
              : '手動待命'
        : '機器人未就緒';
    final color = connected ? AppStyle.green : AppStyle.amber;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: AppStyle.floatShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              !connected
                  ? AppIcons.wifiOff
                  : cruise != null
                  ? AppIcons.gauge
                  : AppIcons.circleDot,
              color: color,
              size: 18,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: AppStyle.ink,
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
