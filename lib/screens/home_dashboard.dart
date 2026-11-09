import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../models/robot_info.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/robot_info_provider.dart';
import '../providers/robot_registry.dart';
import '../providers/weather_provider.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';
import '../widgets/map_task_controls.dart' show selectedZoneOf;
import '../widgets/robot_version_card.dart';

const _bg = AppStyle.bg;
const _ink = AppStyle.ink;
const _muted = AppStyle.muted;
const _green = AppStyle.green;
const _lime = AppStyle.lime;

/// The home page: one look at the robot (is it up, what is it doing, how much
/// battery, how far along) and one big way into it. Read-only: nothing here
/// sends a command.
class DashboardHomePage extends StatelessWidget {
  const DashboardHomePage({
    super.key,
    this.onShowVersions,
    this.onOpenSettings,
    this.onOpenRun,
  });

  final VoidCallback? onShowVersions;

  /// Opens 設定, where the robot settings live.
  final VoidCallback? onOpenSettings;

  /// Opens the map (navigation only; never sends a command).
  final VoidCallback? onOpenRun;

  @override
  Widget build(BuildContext context) {
    final incompatible = context.select<RobotInfoProvider, bool>(
      (p) =>
          p.compatibility == RobotCompatibility.robotTooOld ||
          p.compatibility == RobotCompatibility.appTooOld,
    );
    final mismatch = context.select<RobotRegistry, bool>(
      (r) => r.identityMismatch,
    );
    final running = context.select<MissionMockProvider, bool>(
      (m) =>
          m.navStatus == NavMockStatus.executing ||
          m.navStatus == NavMockStatus.paused,
    );
    return ColoredBox(
      color: _bg,
      child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: ListView(
              // Room at the bottom for the 進入機器 button over it.
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 120),
              physics: const BouncingScrollPhysics(),
              children: [
                _Header(onOpenSettings: onOpenSettings),
                const SizedBox(height: 18),
                if (mismatch) ...[
                  IdentityMismatchNotice(onOpenSettings: onOpenSettings),
                  const SizedBox(height: 12),
                ],
                if (incompatible) ...[
                  CompatibilityNotice(onShowVersions: onShowVersions),
                  const SizedBox(height: 12),
                ],
                const _HeroCard(),
                const SizedBox(height: 14),
                const _AreaRow(),
                const SizedBox(height: 14),
                const _WeatherCard(),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _EnterButton(running: running, onTap: onOpenRun),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({this.onOpenSettings});

  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final robotName = context.select<RobotRegistry, String?>(
      (r) => r.active?.displayName,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '我的割草機',
                style: TextStyle(
                  color: _ink,
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              // Which robot; tapping it goes to 設定 / 我的機器人.
              Material(
                color: Colors.white,
                shape: const StadiumBorder(
                  side: BorderSide(color: Color(0xFFE1E8E4)),
                ),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onOpenSettings,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(AppIcons.bot, size: 18, color: _green),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            robotName ?? '尚未配對機器人',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        const Icon(
                          AppIcons.chevronDown,
                          size: 18,
                          color: _muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Tooltip(
          message: '設定',
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(),
            elevation: 2,
            shadowColor: const Color(0x33000000),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onOpenSettings,
              child: const SizedBox(
                width: 46,
                height: 46,
                child: Icon(AppIcons.settings, color: _ink, size: 22),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The robot at a glance, on a green card: whether it is up, what it is
/// doing and where, battery and progress.
class _HeroCard extends StatelessWidget {
  const _HeroCard();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final demo = mission.mockDataEnabled;
    final online = mission.robotOnline && !demo;
    final connected = demo || mission.rosConnected;

    final (chip, chipDot) = demo
        ? ('Demo 模式', const Color(0xFFFFB547))
        : online
        ? ('在線', _lime)
        : mission.rosConnected
        ? ('離線', const Color(0xFFFF8A80))
        : ('連線中', Colors.white54);

    final executing = mission.navStatus == NavMockStatus.executing;
    final label = mission.navStatusLabel();
    final title = !connected
        ? '未連線'
        : executing
        ? '割草中'
        : label == '待命'
        ? '待命中'
        : label;

    final zone = selectedZoneOf(mission);
    final battery = mission.batteryPercent;
    final progress = coverageOf(mission);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: AppStyle.heroGradient,
        boxShadow: const [
          BoxShadow(
            color: Color(0x40167A4A),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: Stack(
          children: [
            const Positioned.fill(
              child: CustomPaint(painter: _HeroBackdropPainter()),
            ),
            const Positioned(
              right: 6,
              top: 46,
              child: SizedBox(
                width: 168,
                height: 118,
                child: CustomPaint(painter: MowerArtPainter()),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _GlassChip(label: chip, dot: chipDot),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: 170,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          zone?.name ?? '尚未選擇區域',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.78),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 46),
                  Row(
                    children: [
                      Expanded(
                        child: _GlassStat(
                          icon: _batteryIcon(battery),
                          label: '電量',
                          value: battery == null ? '--' : '${battery.round()}%',
                          fraction: battery == null
                              ? null
                              : (battery / 100).clamp(0.0, 1.0),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _GlassStat(
                          icon: AppIcons.sprout,
                          label: '進度',
                          value: progress == null
                              ? '--'
                              : '${(progress * 100).round()}%',
                          fraction: progress,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _batteryIcon(double? percent) {
    if (percent == null) return AppIcons.battery;
    if (percent >= 70) return AppIcons.batteryFull;
    if (percent >= 30) return AppIcons.batteryMedium;
    return AppIcons.batteryLow;
  }
}

/// How far the mowing has got, when that is known: always in the demo, live
/// only once a run has finished (mid-run the robot does not report it yet).
double? coverageOf(MissionMockProvider mission) {
  final progress = mission.coverageProgress.clamp(0.0, 1.0).toDouble();
  final active =
      mission.navStatus == NavMockStatus.executing ||
      mission.navStatus == NavMockStatus.paused;
  final known = mission.mockDataEnabled || (!active && progress >= 1.0);
  return known ? progress : null;
}

double _polygonAreaM2(List<MapPoint> points) {
  if (points.length < 3) return 0;
  var twiceArea = 0.0;
  for (var i = 0; i < points.length; i += 1) {
    final current = points[i];
    final next = points[(i + 1) % points.length];
    twiceArea += current.x * next.y - next.x * current.y;
  }
  return twiceArea.abs() / 2;
}

class _GlassChip extends StatelessWidget {
  const _GlassChip({required this.label, required this.dot});

  final String label;
  final Color dot;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: dot,
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: dot, blurRadius: 6)],
              ),
              child: const SizedBox(width: 8, height: 8),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
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

class _GlassStat extends StatelessWidget {
  const _GlassStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.fraction,
  });

  final IconData icon;
  final String label;
  final String value;
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: _lime),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.78),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: fraction ?? 0,
                minHeight: 5,
                backgroundColor: Colors.white.withValues(alpha: 0.18),
                color: _lime,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected zone's lawn, in numbers.
class _AreaRow extends StatelessWidget {
  const _AreaRow();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final zone = selectedZoneOf(mission);
    final progress = coverageOf(mission);
    final total = zone == null ? null : _polygonAreaM2(zone.points);
    final done = total == null || progress == null
        ? null
        : (total * progress).round();
    final left = total == null || done == null ? null : total.round() - done;
    return Row(
      children: [
        Expanded(
          child: _AreaTile(label: '總面積', value: total?.round()),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _AreaTile(label: '已完成', value: done),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _AreaTile(label: '剩餘', value: left),
        ),
      ],
    );
  }
}

class _AreaTile extends StatelessWidget {
  const _AreaTile({required this.label, required this.value});

  final String label;
  final int? value;

  @override
  Widget build(BuildContext context) {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: _muted,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value == null ? '--' : '$value',
                    style: const TextStyle(
                      color: _ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (value != null)
                    const TextSpan(
                      text: ' m²',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeatherCard extends StatelessWidget {
  const _WeatherCard();

  @override
  Widget build(BuildContext context) {
    final weather = context.watch<WeatherProvider>();
    final snapshot = weather.snapshot;
    final title = weather.isLoading && snapshot == null
        ? '天氣載入中'
        : snapshot?.conditionLabel ?? weather.errorMessage ?? '等待天氣資料';
    final detail = snapshot == null
        ? null
        : '體感 ${snapshot.apparentTemperatureC.round()}° · '
              '濕度 ${snapshot.relativeHumidity}% · '
              '風 ${snapshot.windSpeedKmh.round()} km/h';

    return _Panel(
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      child: Row(
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFFE6F3FF), Color(0xFFD3E9FB)],
              ),
              borderRadius: BorderRadius.circular(16),
            ),
            child: SizedBox(
              width: 50,
              height: 50,
              child: Icon(
                snapshot == null
                    ? AppIcons.cloud
                    : _weatherIcon(snapshot.weatherCode),
                color: const Color(0xFF1E7FD0),
                size: 26,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _ink,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  // Its own line, so a stale reading is never hidden; it
                  // also carries the Open-Meteo credit.
                  [
                    ?detail,
                    snapshot == null
                        ? 'Open-Meteo'
                        : 'Open-Meteo · ${_updated(snapshot.fetchedAt)}',
                  ].join('\n'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _muted,
                    fontSize: 12.5,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (weather.isLoading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            )
          else
            Text(
              snapshot == null ? '--°' : '${snapshot.temperatureC.round()}°',
              style: const TextStyle(
                color: _ink,
                fontSize: 32,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
        ],
      ),
    );
  }

  static String _updated(DateTime at) {
    final diff = DateTime.now().difference(at);
    if (diff.inMinutes < 1) return '剛剛更新';
    if (diff.inHours < 1) return '${diff.inMinutes} 分鐘前更新';
    if (diff.inHours < 24) return '${diff.inHours} 小時前更新';
    final h = at.hour.toString().padLeft(2, '0');
    final m = at.minute.toString().padLeft(2, '0');
    return '$h:$m 更新';
  }

  static IconData _weatherIcon(int code) {
    return switch (code) {
      0 || 1 => AppIcons.sun,
      2 || 3 => AppIcons.cloud,
      45 || 48 => AppIcons.cloudFog,
      51 || 53 || 55 || 56 || 57 => AppIcons.cloudDrizzle,
      61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => AppIcons.droplet,
      71 || 73 || 75 || 77 || 85 || 86 => AppIcons.snowflake,
      95 || 96 || 99 => AppIcons.cloudLightning,
      _ => AppIcons.cloud,
    };
  }
}

/// A white rounded panel on the page.
class _Panel extends StatelessWidget {
  const _Panel({required this.child, required this.padding});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: AppStyle.panelShadow,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// The page's one action, always at hand at the bottom.
class _EnterButton extends StatelessWidget {
  const _EnterButton({required this.running, required this.onTap});

  final bool running;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // The page fades out under it instead of being cut off.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_bg.withValues(alpha: 0), _bg, _bg],
          stops: const [0, 0.35, 1],
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 4),
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            elevation: 8,
            shadowColor: const Color(0x66167A4A),
            child: Ink(
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: AppStyle.goGradient,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onTap,
                child: Row(
                  children: [
                    const SizedBox(width: 20),
                    Icon(
                      running ? AppIcons.circlePlay : AppIcons.map,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        '進入機器',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: BoxShape.circle,
                      ),
                      child: const SizedBox(
                        width: 36,
                        height: 36,
                        child: Icon(
                          AppIcons.arrowRight,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
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

/// Soft shapes behind the hero: two light circles and a few mowing stripes.
class _HeroBackdropPainter extends CustomPainter {
  const _HeroBackdropPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    canvas.drawCircle(
      Offset(w * 0.86, h * 0.12),
      w * 0.42,
      Paint()..color = Colors.white.withValues(alpha: 0.06),
    );
    canvas.drawCircle(
      Offset(w * 0.98, h * 0.02),
      w * 0.24,
      Paint()..color = Colors.white.withValues(alpha: 0.05),
    );
    // Mowing stripes across the bottom, as a freshly cut lawn has.
    final stripe = Paint()..color = Colors.white.withValues(alpha: 0.035);
    canvas.save();
    canvas.translate(0, h * 0.62);
    canvas.skew(-0.35, 0);
    for (var x = -w * 0.2; x < w * 1.4; x += 44) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 22, h), stripe);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HeroBackdropPainter oldDelegate) => false;
}

/// A robot mower, side on: big rear wheel, small front one, a green top
/// shell and the RTK antenna mast.
class MowerArtPainter extends CustomPainter {
  const MowerArtPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Ground shadow.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(w * 0.52, h * 0.93),
        width: w * 0.86,
        height: h * 0.1,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // RTK antenna, behind the body.
    final mastX = w * 0.58;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(mastX - w * 0.012, h * 0.1, w * 0.024, h * 0.3),
        const Radius.circular(3),
      ),
      Paint()..color = const Color(0xFF26332D),
    );
    final disc = Rect.fromCenter(
      center: Offset(mastX, h * 0.1),
      width: w * 0.22,
      height: h * 0.075,
    );
    canvas.drawOval(
      disc,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFF6F9F7), Color(0xFFB5C3BC)],
        ).createShader(disc),
    );

    // Body.
    final bodyRect = Rect.fromLTWH(w * 0.05, h * 0.36, w * 0.9, h * 0.42);
    final body = RRect.fromRectAndCorners(
      bodyRect,
      topLeft: Radius.circular(h * 0.22),
      topRight: Radius.circular(h * 0.28),
      bottomLeft: Radius.circular(h * 0.08),
      bottomRight: Radius.circular(h * 0.14),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFFFFFFF), Color(0xFFD3DDD8)],
        ).createShader(bodyRect),
    );
    // Dark skirt along the bottom.
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(w * 0.05, h * 0.64, w * 0.9, h * 0.14),
        bottomLeft: Radius.circular(h * 0.08),
        bottomRight: Radius.circular(h * 0.14),
      ),
      Paint()..color = const Color(0xFF24302A),
    );
    // Green top shell, with a highlight.
    final shellRect = Rect.fromLTWH(w * 0.2, h * 0.27, w * 0.6, h * 0.21);
    canvas.drawRRect(
      RRect.fromRectAndRadius(shellRect, Radius.circular(h * 0.105)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF34B373), Color(0xFF0F5A36)],
        ).createShader(shellRect),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.27, h * 0.3, w * 0.3, h * 0.04),
        Radius.circular(h * 0.02),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.38),
    );
    // Lime accent line and the headlight.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.4, h * 0.585, w * 0.52, h * 0.028),
        const Radius.circular(2),
      ),
      Paint()..color = _lime,
    );
    final lamp = Offset(w * 0.9, h * 0.5);
    canvas.drawCircle(
      lamp,
      h * 0.07,
      Paint()
        ..color = const Color(0x66FFF3B0)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: lamp, width: w * 0.06, height: h * 0.055),
        Radius.circular(h * 0.03),
      ),
      Paint()..color = const Color(0xFFFFF7D1),
    );

    // Wheels: the big drive wheel at the back, a small one in front.
    _wheel(canvas, Offset(w * 0.27, h * 0.76), h * 0.2);
    _wheel(canvas, Offset(w * 0.8, h * 0.83), h * 0.105);
  }

  static void _wheel(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF1A2420));
    canvas.drawCircle(
      c,
      r * 0.8,
      Paint()
        ..color = const Color(0xFF34423B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.12,
    );
    final hub = Rect.fromCircle(center: c, radius: r * 0.42);
    canvas.drawCircle(
      c,
      r * 0.42,
      Paint()
        ..shader = const RadialGradient(
          colors: [Color(0xFFEFF4F1), Color(0xFF98AAA1)],
        ).createShader(hub),
    );
  }

  @override
  bool shouldRepaint(covariant MowerArtPainter oldDelegate) => false;
}
