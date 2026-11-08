import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';
import '../providers/phone_location_provider.dart';
import '../providers/robot_fleet_provider.dart';
import 'recorder_screen.dart';
import 'robots_screen.dart';
import '../widgets/add_object_sheet.dart';
import '../widgets/front_camera_pip.dart';
import '../widgets/manual_control_overlay.dart';
import '../widgets/manual_speed_setting.dart';
import '../widgets/mission_map_canvas.dart';
import '../widgets/map_task_controls.dart';
import '../services/google_map_tiles.dart';
import '../widgets/satellite_map_view.dart';
import '../widgets/operation_log_sheet.dart';
import '../widgets/robot_info_popup.dart';
import '../widgets/robot_version_card.dart';
import '../widgets/site_library_sheet.dart';
import '../widgets/top_status_pill.dart';
import 'home_dashboard.dart';
import 'imagery_alignment_screen.dart';
import 'self_check_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _selfCheckComplete = false;

  @override
  Widget build(BuildContext context) {
    if (!_selfCheckComplete) {
      return SelfCheckScreen(
        onComplete: () => setState(() => _selfCheckComplete = true),
      );
    }

    return const _MowerDashboardShell();
  }
}

void _showAppSheet(BuildContext context, Widget child) {
  showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      return DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: child,
      );
    },
  );
}

class _MowerDashboardShell extends StatefulWidget {
  const _MowerDashboardShell();

  @override
  State<_MowerDashboardShell> createState() => _MowerDashboardShellState();
}

class _MowerDashboardShellState extends State<_MowerDashboardShell> {
  static const _homePage = 0;
  static const _mapPage = 1;

  /// No tab bar: the home page's 進入機器 opens the map, and the map has its
  /// own buttons back home and to 設定.
  int _page = _homePage;
  final _mapKey = GlobalKey<_MissionMapScreenState>();

  /// Leaving the map stops the robot: its joysticks go with it.
  void _showPage(int page) {
    if (page != _mapPage) _mapKey.currentState?.haltDriving();
    setState(() => _page = page);
  }

  /// 設定 is a page of its own over the current one. The robot stops first:
  /// the page covers the joysticks (and a cruise that drives on its own).
  void _openSettings() {
    _mapKey.currentState?.haltDriving();
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _SettingsPage()));
  }

  @override
  Widget build(BuildContext context) {
    // Android's back from the map goes home, not out of the app.
    return PopScope(
      canPop: _page == _homePage,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showPage(_homePage);
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF6F7F8),
        body: IndexedStack(
          index: _page,
          children: [
            DashboardHomePage(
              onShowVersions: _openSettings,
              onOpenSettings: _openSettings,
              onOpenRun: () {
                // The map comes up with the selected zone's buttons out.
                _mapKey.currentState?.revealPanel();
                _showPage(_mapPage);
              },
            ),
            // Operating pages are blocked while the robot's API version is
            // outside what this app supports (see RobotInfoProvider).
            CompatibilityGate(
              onShowVersions: _openSettings,
              onHome: () => _showPage(_homePage),
              child: MissionMapScreen(
                key: _mapKey,
                active: _page == _mapPage,
                onHome: () => _showPage(_homePage),
                onSettings: _openSettings,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The app's one settings page, opened from the map or the home header.
class _SettingsPage extends StatelessWidget {
  const _SettingsPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: const _SettingsTab(visible: true),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The home page's panels: white, rounded, on a soft shadow.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppStyle.panelShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: child,
      ),
    );
  }
}

class _SettingsTab extends StatelessWidget {
  const _SettingsTab({required this.visible});

  /// This tab is on screen (the shell keeps every tab alive).
  final bool visible;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    // The app's one settings page: robots and their 直連 IP are edited right
    // here, not on a separate page. Grouped like the home page's cards.
    void push(Widget page) => Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    return ColoredBox(
      color: AppStyle.bg,
      child: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          physics: const BouncingScrollPhysics(),
          children: [
            RobotSettingsSection(visible: visible),
            const SizedBox(height: 26),
            const AppSectionTitle('駕駛與工具'),
            _DashboardCard(
              child: Column(
                children: [
                  const ManualSpeedSetting(),
                  const Divider(height: 22),
                  _SettingsActionRow(
                    icon: AppIcons.video,
                    title: '錄製 / Bag',
                    onTap: () => push(const RecorderScreen()),
                  ),
                  const Divider(height: 14, indent: 50),
                  _SettingsActionRow(
                    icon: AppIcons.list,
                    title: '操作日誌',
                    onTap: () => push(
                      Scaffold(
                        appBar: AppBar(title: const Text('操作日誌')),
                        body: const SingleChildScrollView(
                          padding: EdgeInsets.all(16),
                          child: OperationLogSheet(),
                        ),
                      ),
                    ),
                  ),
                  // Only builds with a Google key show Google's photo to
                  // align.
                  if (GoogleMapTiles.shared.configured) ...[
                    const Divider(height: 14, indent: 50),
                    _SettingsActionRow(
                      icon: AppIcons.crosshair,
                      title: '衛星圖對位',
                      onTap: () =>
                          push(ImageryAlignmentScreen(mission: mission)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 26),
            const AppSectionTitle('機器人軟體'),
            const _DashboardCard(child: RobotVersionCard()),
            const SizedBox(height: 26),
            _DashboardCard(child: _AdvancedSection(mission: mission)),
          ],
        ),
      ),
    );
  }
}

/// Connection / data-source tools that ordinary use never needs, folded away
/// so they stop competing with the everyday rows above.
class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({required this.mission});

  final MissionMockProvider mission;

  @override
  Widget build(BuildContext context) {
    // ListTile-based children paint ink on the nearest Material; the card is a
    // plain DecoratedBox, so give them a transparent one to draw on.
    return Material(
      type: MaterialType.transparency,
      child: Theme(
        // The card already has its own frame; drop ExpansionTile's dividers.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 4),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          leading: const AppIconTile(AppIcons.settings, color: AppStyle.muted),
          title: const Text(
            '進階',
            style: TextStyle(
              color: AppStyle.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          children: [
            const _DemoModeTile(),
            const SizedBox(height: 8),
            _InfoRow(
              icon: mission.rosConnected
                  ? AppIcons.circleDot
                  : AppIcons.wifiOff,
              title: '資料來源',
              detail: mission.mockDataEnabled
                  ? 'Demo'
                  : mission.rosConnected
                  ? (mission.robotOnline ? '機器人在線' : '已連線')
                  : '等待連線',
            ),
            _InfoRow(
              icon: AppIcons.link,
              title: 'rosbridge',
              detail: mission.rosbridgeUrl,
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  const _SettingsActionRow({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            AppIconTile(icon),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  color: AppStyle.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Icon(AppIcons.chevronRight, color: AppStyle.muted, size: 20),
          ],
        ),
      ),
    );
  }
}

class MissionMapScreen extends StatefulWidget {
  const MissionMapScreen({
    super.key,
    this.active = true,
    this.onHome,
    this.onSettings,
  });

  /// Whether this page is the one on screen. The joysticks leave (and stop
  /// the robot) while the home page is shown.
  final bool active;

  /// The top corners' buttons: back to the home page, and 設定. The robot
  /// stops before either is called.
  final VoidCallback? onHome;
  final VoidCallback? onSettings;

  @override
  State<MissionMapScreen> createState() => _MissionMapScreenState();
}

class _MissionMapScreenState extends State<MissionMapScreen>
    with WidgetsBindingObserver {
  final _canvasKey = GlobalKey<MissionMapCanvasState>();
  final _sticksKey = GlobalKey<ManualControlOverlayState>();
  Offset? _popupOffset;
  int? _dragVertexIndex;

  /// The operator tapped the selected zone on the map, so its buttons
  /// (設定, 生成路徑 / 開始割草) float above the right stick. A tap on empty
  /// map puts them away.
  bool _zoneFocused = false;

  /// The phase at the last build: a recording that just ended focuses the
  /// zone it made.
  TaskPhase? _lastPhase;

  /// Keep the map centred on the robot. Always the default, with no button:
  /// dragging the satellite map pauses it, and it picks up again a few
  /// seconds after the last drag, or at once when the sticks drive.
  bool _followRobot = true;

  /// The joysticks are sending motion: the map keeps the robot in view and
  /// holds still under the thumbs.
  bool _sticksMoving = false;

  /// The front camera picture-in-picture. Off until the operator turns it on:
  /// with no viewer the robot does not stream it.
  bool _cameraOn = false;
  bool _cameraExpanded = false;

  /// Where snackbars float: above the sticks and their buttons.
  double _snackBottom = 0;

  /// The phone's location was asked for once already this run.
  bool _phoneLocationTried = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.active) _autoStartPhoneLocation();
  }

  @override
  void didUpdateWidget(MissionMapScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _autoStartPhoneLocation();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Location allowed in the system settings meanwhile: on it goes, without
    // asking again.
    if (state == AppLifecycleState.resumed && _phoneLocationTried) {
      final phone = context.read<PhoneLocationProvider>();
      if (!phone.enabled) unawaited(phone.start(prompt: false));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The phone's own position shows on the map whenever the phone allows it.
  /// There is no button for it: the first time the map is shown it asks for
  /// the permission once, and a no (or location off) leaves it off quietly.
  void _autoStartPhoneLocation() {
    if (_phoneLocationTried) return;
    _phoneLocationTried = true;
    // After this frame: it is called while the page builds.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final phone = context.read<PhoneLocationProvider>();
      if (!phone.enabled) unawaited(phone.start());
    });
  }

  /// Stops the robot and centres the sticks. Called before anything covers
  /// them and when the page goes out of view.
  void haltDriving() => _sticksKey.currentState?.halt();

  /// Shows the selected zone's buttons (used when another tab sends the user
  /// here to run a mission).
  void revealPanel() {
    if (!_zoneFocused) {
      setState(() => _zoneFocused = true);
    }
  }

  /// 設定: the phase's panels in a sheet over the map.
  void _openDetails() => _showSheet(const TaskDetailsSheet());

  void _showSheet(Widget sheet) {
    haltDriving();
    _showAppSheet(context, sheet);
  }

  void _onSticksMoving(bool moving) {
    if (moving == _sticksMoving || !mounted) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setSticksMoving(moving);
      });
      return;
    }
    _setSticksMoving(moving);
  }

  /// Driving also turns following back on: the robot is what you steer.
  void _setSticksMoving(bool moving) {
    setState(() {
      _sticksMoving = moving;
      if (moving) _followRobot = true;
    });
  }

  /// A locked stick was tapped. During mowing that is the way to stop the
  /// task (phase 1: there is no takeover that keeps the mission); otherwise
  /// it says why the sticks are locked.
  void _onLockedStickTap(String reason) {
    final mission = context.read<MissionMockProvider>();
    if (mission.manualDriveLockedByMission) {
      unawaited(confirmStopMowing(context, mission, fromSticks: true));
      return;
    }
    final text = switch (reason) {
      '示範模式' => '示範模式不會控制真的割草機，搖桿不能用',
      '連線中斷' => '和割草機的連線中斷了，搖桿先鎖住，正在重新連線',
      '等待確認停止' => '正在等機器人確認任務已停止，確認後搖桿就會解鎖',
      '生成路徑中' => '正在生成路徑，完成後搖桿就會解鎖',
      '請先放開搖桿' => '請先放開搖桿，再重新推一次',
      _ => '搖桿暫時不能用：$reason',
    };
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, _snackBottom),
        ),
      );
  }

  /// Index of the edit-polygon vertex nearest to a screen point, within a
  /// grab radius; null if none.
  int? _vertexAt(Offset local, {double radius = 30.0}) {
    final proj = _canvasKey.currentState?.lastProjection;
    if (proj == null) return null;
    final pts = context.read<MissionMockProvider>().editPolygon;
    int? nearest;
    var best = radius;
    for (var i = 0; i < pts.length; i++) {
      final d = (proj.project(pts[i]) - local).distance;
      if (d < best) {
        best = d;
        nearest = i;
      }
    }
    return nearest;
  }

  void _onLongPress(LongPressStartDetails details) {
    final mission = context.read<MissionMockProvider>();
    // In vertex-edit mode, a long-press on a vertex deletes it.
    if (mission.editVertexMode) {
      final vi = _vertexAt(details.localPosition);
      if (vi != null) mission.deleteVertex(vi);
      return;
    }
    final positions = _canvasKey.currentState?.robotScreenPositions ?? {};
    const threshold = 44.0;
    int? nearest;
    double nearestDist = double.infinity;
    for (final entry in positions.entries) {
      final dist = (details.localPosition - entry.value).distance;
      if (dist < threshold && dist < nearestDist) {
        nearestDist = dist;
        nearest = entry.key;
      }
    }
    if (nearest != null) {
      context.read<RobotFleetProvider>().selectRobot(nearest);
      setState(() => _popupOffset = positions[nearest]);
    }
  }

  /// The one way to add a zone, no-go zone or channel. Recording starts on
  /// the robot from there; the sticks are already on the map to drive it.
  void _openAddObject() => _showSheet(const AddObjectSheet());

  void _dismissPopup() {
    context.read<RobotFleetProvider>().selectRobot(null);
    setState(() => _popupOffset = null);
  }

  Offset _clampedPopupOrigin(Offset robotPos, Size screenSize) {
    const popupW = 220.0;
    const popupH = 148.0;
    final left = (robotPos.dx - popupW / 2).clamp(
      8.0,
      screenSize.width - popupW - 8,
    );
    final double top;
    if (robotPos.dy > screenSize.height * 0.55) {
      top = (robotPos.dy - popupH - 32).clamp(
        8.0,
        screenSize.height - popupH - 8,
      );
    } else {
      top = (robotPos.dy + 32).clamp(8.0, screenSize.height - popupH - 8);
    }
    return Offset(left, top);
  }

  /// The camera's box: a small picture-in-picture under the right-hand
  /// buttons; enlarged, as wide as the map beside the left-hand buttons
  /// (portrait) or a bigger corner view (landscape).
  Rect _cameraRect(Size size, EdgeInsets pad, bool isPortrait) {
    final sideR = math.max(12.0, pad.right);
    final w = isPortrait
        // Enlarged it stops short of the left-hand buttons (the camera
        // switch among them), so it can always be turned off.
        ? _cameraExpanded
              ? size.width - 70 - sideR
              : math.min(size.width * 0.36, 150.0)
        : _cameraExpanded
        ? math.min(size.width * 0.42, size.width / 2 - 32 - sideR)
        : math.min(size.width * 0.22, 190.0);
    // Under the status pill (and a recording's chip); the right side has no
    // buttons any more.
    final top = isPortrait ? pad.top + 120 : pad.top + 10;
    return Rect.fromLTWH(size.width - sideR - w, top, w, w * 9 / 16);
  }

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final fleet = context.watch<RobotFleetProvider>();
    final phone = context.watch<PhoneLocationProvider>();
    // The phone's GPS fix in the map frame; needs the map's geo anchor.
    final phoneWorld = (phone.position != null && mission.mapGeoAnchor != null)
        ? mission.mapGeoAnchor!.latLngToWorld(phone.position!)
        : null;
    final media = MediaQuery.of(context);
    final size = media.size;
    final isLandscape = size.width > size.height;

    // No bar along the bottom: the sticks sit right above the tab bar, and
    // the phase's buttons float above the right stick.
    final phase = taskPhaseOf(mission);
    final last = _lastPhase;
    _lastPhase = phase;
    if ((last == TaskPhase.recording || last == TaskPhase.pendingSave) &&
        phase != TaskPhase.recording &&
        phase != TaskPhase.pendingSave &&
        selectedZoneOf(mission) != null) {
      // A zone just saved: go straight on to its path.
      _zoneFocused = true;
    }
    final sticksHidden =
        !widget.active || mission.drawMode || mission.editVertexMode;
    final sticksTop = ManualControlOverlay.controlsClearance(size);
    final controlsShown =
        !sticksHidden && taskControlsShown(phase, zoneFocused: _zoneFocused);
    // Snackbars clear the sticks and the buttons over them.
    _snackBottom = sticksHidden ? 12 : sticksTop + 70;

    // Paused while drawing / editing vertices so the map holds still under
    // the finger. Driving always follows: the robot is what you steer.
    final following =
        (_followRobot || _sticksMoving) &&
        mission.shouldShowRobot &&
        !mission.drawMode &&
        !mission.editVertexMode;

    final selectedRobot = fleet.selectedRobot;
    final popupOrigin = (_popupOffset != null && selectedRobot != null)
        ? _clampedPopupOrigin(_popupOffset!, size)
        : null;

    return Scaffold(
      body: GestureDetector(
        onLongPressStart: _onLongPress,
        // Pan handlers exist ONLY in vertex-edit mode; otherwise they are null
        // so the PanGestureRecognizer doesn't compete with the panel's scroll.
        onPanStart: mission.editVertexMode
            ? (details) => setState(
                () => _dragVertexIndex = _vertexAt(details.localPosition),
              )
            : null,
        onPanUpdate: mission.editVertexMode
            ? (details) {
                if (_dragVertexIndex == null) return;
                final proj = _canvasKey.currentState?.lastProjection;
                if (proj == null) return;
                mission.moveVertex(
                  _dragVertexIndex!,
                  proj.unproject(details.localPosition),
                );
              }
            : null,
        onPanEnd: mission.editVertexMode
            ? (_) {
                if (_dragVertexIndex != null) {
                  setState(() => _dragVertexIndex = null);
                }
              }
            : null,
        onTapUp: (details) {
          // Drawing takes precedence over robot-popup dismissal / selection,
          // so the first tap after entering draw mode drops a vertex.
          if (mission.drawMode) {
            if (details.localPosition.dy > size.height - 12) {
              return;
            }
            final proj = _canvasKey.currentState?.lastProjection;
            if (proj != null) {
              mission.addDraftVertex(proj.unproject(details.localPosition));
            }
            return;
          }
          // In vertex-edit a tap must not re-run selection; only dismiss a
          // popup.
          if (mission.editVertexMode) {
            if (fleet.selectedRobotId != null) _dismissPopup();
            return;
          }
          if (fleet.selectedRobotId != null) {
            _dismissPopup();
            return;
          }
          // Taps in the band the sticks sit in are not map taps.
          if (!sticksHidden &&
              details.localPosition.dy > size.height - sticksTop) {
            return;
          }
          final proj = _canvasKey.currentState?.lastProjection;
          if (proj == null) return;
          final world = proj.unproject(details.localPosition);
          final wRight = proj.unproject(
            details.localPosition + const Offset(22, 0),
          );
          final tol = math
              .sqrt(
                math.pow(wRight.x - world.x, 2) +
                    math.pow(wRight.y - world.y, 2),
              )
              .toDouble();
          if (!mission.selectObjectAt(world, channelTol: tol)) {
            // Empty map puts the zone's buttons away.
            mission.clearObjectSelection();
            if (_zoneFocused) setState(() => _zoneFocused = false);
            return;
          }
          // One selection: a zone tapped on the map is the zone that is
          // planned and mown, and its buttons come up.
          final id = mission.selectedObjectId;
          if (mission.selectedObjectKind == 'zone' && id != null) {
            mission.selectZone(id);
            setState(() => _zoneFocused = true);
          }
        },
        child: Stack(
          children: [
            // The one map, in its own layer so nothing drawn above it (the
            // joysticks, the camera) repaints it. While drawing, force the
            // vector canvas (it owns the projection that tap-to-vertex
            // needs); satellite has no projection yet.
            if (mission.satelliteBaseMap &&
                mission.mapGeoAnchor != null &&
                !mission.drawMode &&
                !mission.editVertexMode)
              // Sized to the area above the panel (reaching under its rounded
              // corners, resizing with it) so the framing and the followed
              // robot are centred in what is visible.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                left: 0,
                top: 0,
                right: 0,
                bottom: 0,
                child: RepaintBoundary(
                  child: SatelliteMapView(
                    mission: mission,
                    anchor: mission.mapGeoAnchor!,
                    phonePosition: phone.position,
                    phoneAccuracyM: phone.accuracyM,
                    followRobot: following,
                    onFollowRobotChanged: (on) =>
                        setState(() => _followRobot = on),
                    resumeFollowAfter: const Duration(seconds: 8),
                    lockPan: _sticksMoving,
                    bottomInset: sticksHidden ? 0 : sticksTop,
                    animateMarker: !_sticksMoving,
                    aiEnhance: mission.aiBaseMap,
                  ),
                ),
              )
            else
              Positioned.fill(
                child: RepaintBoundary(
                  child: MissionMapCanvas(
                    key: _canvasKey,
                    mission: mission,
                    robots: fleet.robots,
                    selectedRobotId: fleet.selectedRobotId,
                    bottomInset: 0,
                    // Its corner is where the left joystick sits.
                    showScalePill: sticksHidden,
                    phonePosition: phoneWorld,
                    phoneAccuracyM: phone.accuracyM,
                    centerOn: following ? mission.robotPosition : null,
                  ),
                ),
              ),
            Positioned(
              top: media.padding.top + 10,
              // Clear of the buttons on the left; a narrow phone shrinks it.
              left: 70,
              right: 70,
              child: const Center(
                child: FittedBox(fit: BoxFit.scaleDown, child: TopStatusPill()),
              ),
            ),
            // Every map button in one column down the left, the right side
            // left to the map, the camera and the task buttons. Where one
            // column does not fit above the sticks (landscape) it wraps into
            // a second.
            Positioned(
              top: media.padding.top + 8,
              left: math.max(12.0, media.padding.left),
              bottom: sticksHidden ? 80 : sticksTop + 8,
              child: Wrap(
                direction: Axis.vertical,
                spacing: 10,
                runSpacing: 10,
                children: [
                  if (widget.onHome != null)
                    _MapButton(
                      icon: AppIcons.house,
                      tooltip: '回主畫面',
                      onTap: () {
                        haltDriving();
                        widget.onHome!();
                      },
                    ),
                  if (widget.onSettings != null)
                    _MapButton(
                      icon: AppIcons.settings,
                      tooltip: '設定',
                      onTap: () {
                        haltDriving();
                        widget.onSettings!();
                      },
                    ),
                  _MapButton(
                    icon: AppIcons.satellite,
                    tooltip: mission.satelliteBaseMap ? '關閉衛星圖' : '打開衛星圖',
                    on: mission.satelliteBaseMap,
                    // Needs the map's GPS position to place the photo.
                    onTap: mission.mapGeoAnchor == null
                        ? null
                        : mission.toggleSatelliteBaseMap,
                  ),
                  _MapButton(
                    icon: _cameraOn ? AppIcons.video : AppIcons.videoOff,
                    tooltip: _cameraOn ? '關閉前鏡頭' : '打開前鏡頭',
                    on: _cameraOn,
                    onTap: () => setState(() {
                      _cameraOn = !_cameraOn;
                      _cameraExpanded = false;
                    }),
                  ),
                  _MapButton(
                    icon: AppIcons.plus,
                    tooltip: '新增物件',
                    iconColor: const Color(0xFF1384E8),
                    onTap: _openAddObject,
                  ),
                  _MapButton(
                    icon: AppIcons.download,
                    tooltip: '場地庫',
                    onTap: () => _showSheet(const SiteLibrarySheet()),
                  ),
                ],
              ),
            ),
            if (mission.drawMode)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: _DrawControlBar(
                  count: mission.draftPolygon.length,
                  onUndo: mission.undoDraftVertex,
                  onCancel: mission.cancelDraw,
                  onCommit: mission.commitDraw,
                ),
              ),
            if (mission.editVertexMode)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: _VertexEditBar(
                  count: mission.editPolygon.length,
                  onCancel: mission.cancelVertexEdit,
                  onCommit: mission.commitVertexEdit,
                ),
              ),
            // The joysticks: always on the map, over the bar's line.
            Positioned.fill(
              child: ManualControlOverlay(
                key: _sticksKey,
                mission: mission,
                hidden: sticksHidden,
                onLockedTap: _onLockedStickTap,
                onMovingChanged: _onSticksMoving,
              ),
            ),
            if (_cameraOn && widget.active)
              AnimatedPositioned.fromRect(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeInOut,
                rect: _cameraRect(size, media.padding, !isLandscape),
                child: FrontCameraPip(
                  mission: mission,
                  expanded: _cameraExpanded,
                  // Never flush with an edge any more: rounded all round.
                  banner: false,
                  onTap: () =>
                      setState(() => _cameraExpanded = !_cameraExpanded),
                ),
              ),
            // The phase's buttons, just above the right stick.
            if (controlsShown)
              Positioned(
                right: math.max(18.0, media.padding.right),
                bottom: sticksTop + 6,
                child: MapTaskControls(
                  phase: phase,
                  onDetails: _openDetails,
                  beforeModal: haltDriving,
                  snackBottom: _snackBottom,
                ),
              ),
            // A recording's time and points, under the robot status.
            Positioned(
              top: media.padding.top + 56,
              left: 70,
              right: 70,
              child: const Center(child: MapRecordChip()),
            ),
            if (popupOrigin != null && selectedRobot != null)
              Positioned(
                left: popupOrigin.dx,
                top: popupOrigin.dy,
                width: 220,
                child: RobotInfoPopup(
                  robot: selectedRobot,
                  onClose: _dismissPopup,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DrawControlBar extends StatelessWidget {
  const _DrawControlBar({
    required this.count,
    required this.onUndo,
    required this.onCancel,
    required this.onCommit,
  });

  final int count;
  final VoidCallback onUndo;
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final canSave = count >= 3;
    final compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    // Swallow taps on the bar (incl. rounded-corner gaps) so they don't drop
    // a map vertex behind it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {},
      // A white card on a soft shadow, like the map's other panels.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppStyle.floatShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(
                  AppIcons.mapPinPen,
                  color: Color(0xFFE5852F),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '點地圖加頂點 · $count 點',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppStyle.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: count > 0 ? onUndo : null,
                  style: compact.copyWith(
                    foregroundColor: WidgetStateProperty.all(AppStyle.ink),
                  ),
                  child: const Text('復原'),
                ),
                TextButton(
                  onPressed: onCancel,
                  style: compact.copyWith(
                    foregroundColor: WidgetStateProperty.all(AppStyle.muted),
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: canSave ? onCommit : null,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('閉合儲存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VertexEditBar extends StatelessWidget {
  const _VertexEditBar({
    required this.count,
    required this.onCancel,
    required this.onCommit,
  });

  final int count;
  final VoidCallback onCancel;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {},
      // A white card on a soft shadow, like the map's other panels.
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: AppStyle.floatShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                const Icon(AppIcons.move, color: Color(0xFF1384E8), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '拖曳頂點 · 長按刪除 · $count 點',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppStyle.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: AppStyle.muted,
                  ),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 4),
                FilledButton(
                  onPressed: onCommit,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('完成儲存'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A button in the map's left column, in the home page's style: white and
/// round on a soft shadow; green while what it turns on is on; greyed out
/// when it cannot be used.
class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.on = false,
    this.iconColor,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool on;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final lit = on && enabled;
    final foreground = !enabled
        ? const Color(0xFFB0BEC5)
        : lit
        ? Colors.white
        : iconColor ?? AppStyle.ink;
    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: lit ? null : Colors.white,
          gradient: lit ? AppStyle.heroGradient : null,
          boxShadow: lit ? AppStyle.glow(AppStyle.green) : AppStyle.floatShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Icon(icon, color: foreground, size: 22),
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoModeTile extends StatelessWidget {
  const _DemoModeTile();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        'Demo 模式',
        style: TextStyle(
          color: AppStyle.ink,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      value: mission.mockDataEnabled,
      onChanged: connectionSettingsLocked(mission)
          ? null
          : (value) {
              unawaited(mission.setMockDataEnabled(value));
            },
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: AppStyle.muted, size: 20),
          const SizedBox(width: 12),
          Text(
            title,
            style: const TextStyle(
              color: AppStyle.ink,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 12),
          // The value on the same line, not a second line of small print.
          Expanded(
            child: Text(
              detail,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF78909C),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
