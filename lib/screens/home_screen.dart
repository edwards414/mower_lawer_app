import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/mower_status_provider.dart';
import '../providers/weather_provider.dart';
import '../services/rosbridge_service.dart';
import '../providers/robot_fleet_provider.dart';
import '../widgets/add_object_sheet.dart';
import '../widgets/execution_control_sheet.dart';
import '../widgets/manual_control_overlay.dart';
import '../widgets/map_objects_sheet.dart';
import '../widgets/mission_map_canvas.dart';
import '../widgets/mission_mode_bar.dart';
import '../widgets/operation_log_sheet.dart';
import '../widgets/planning_control_sheet.dart';
import '../widgets/record_control_sheet.dart';
import '../widgets/robot_info_popup.dart';
import '../widgets/top_status_pill.dart';
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
  int _selectedIndex = 0;
  MissionMockProvider? _mission;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _mission = context.read<MissionMockProvider>();
  }

  @override
  void dispose() {
    if (_selectedIndex == 2) {
      _mission?.stopManualControl();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F8),
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          const _DashboardHomePage(),
          MissionMapScreen(onManual: () => setState(() => _selectedIndex = 2)),
          _ManualControlTab(
            onGoHome: () {
              context.read<MissionMockProvider>().stopManualControl();
              setState(() => _selectedIndex = 0);
            },
          ),
          const _ScheduleTab(),
          const _MoreTab(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 70,
        selectedIndex: _selectedIndex,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorColor: const Color(0xFFE3F5EA),
        onDestinationSelected: (index) {
          if (_selectedIndex == 2 && index != 2) {
            context.read<MissionMockProvider>().stopManualControl();
          }
          setState(() => _selectedIndex = index);
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            label: '首頁',
          ),
          NavigationDestination(
            icon: Icon(Icons.map_outlined),
            label: '地圖',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_esports_outlined),
            label: '手動控制',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            label: '排程',
          ),
          NavigationDestination(
            icon: Icon(Icons.more_horiz_outlined),
            label: '更多',
          ),
        ],
      ),
    );
  }
}

class _ManualControlTab extends StatefulWidget {
  const _ManualControlTab({required this.onGoHome});

  final VoidCallback onGoHome;

  @override
  State<_ManualControlTab> createState() => _ManualControlTabState();
}

class _ManualControlTabState extends State<_ManualControlTab> {
  CameraFeed _cameraFeed = CameraFeed.front;

  @override
  Widget build(BuildContext context) {
    return Consumer<MissionMockProvider>(
      builder: (context, mission, _) => ManualControlOverlay(
        mission: mission,
        cameraFeed: _cameraFeed,
        onCameraFeedChanged: (feed) => setState(() => _cameraFeed = feed),
        onExit: widget.onGoHome,
      ),
    );
  }
}

class _DashboardHomePage extends StatelessWidget {
  const _DashboardHomePage();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF6F7F8),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          physics: const BouncingScrollPhysics(),
          children: const [
            _DashboardHeader(),
            SizedBox(height: 16),
            _ConnectionCard(),
            SizedBox(height: 10),
            _WeatherCard(),
            SizedBox(height: 10),
            _BatteryCard(),
            SizedBox(height: 10),
            _MissionSummaryCard(),
            SizedBox(height: 10),
            _NextScheduleCard(),
            SizedBox(height: 10),
            _DockStatusCard(),
          ],
        ),
      ),
    );
  }
}

class _DashboardHeader extends StatelessWidget {
  const _DashboardHeader();

  @override
  Widget build(BuildContext context) {
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
                  color: Color(0xFF17211C),
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'GM-3000',
                    style: TextStyle(
                      color: Color(0xFF50605A),
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(width: 4),
                  Icon(Icons.keyboard_arrow_down, size: 20),
                ],
              ),
            ],
          ),
        ),
        Tooltip(
          message: '通知',
          child: IconButton(
            onPressed: () {},
            icon: const Icon(Icons.notifications_none_outlined),
            color: const Color(0xFF17211C),
          ),
        ),
      ],
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final mowerStatus = context.watch<MowerStatusProvider>().status;
    final online = mission.rosConnected || mission.mockDataEnabled;
    final statusLabel = online ? '在線上' : '等待連線';
    final detail = mission.rosConnected
        ? 'ROS 即時資料 · 最後更新：剛剛'
        : mission.mockDataEnabled
        ? 'Mock fallback · 最後更新：剛剛'
        : mowerStatus == null
        ? '狀態讀取中'
        : '等待 ROS 真實資料';

    return _DashboardCard(
      child: Row(
        children: [
          const SizedBox(
            width: 96,
            height: 62,
            child: CustomPaint(painter: _MowerMiniPainter()),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      statusLabel,
                      style: TextStyle(
                        color: online
                            ? const Color(0xFF168848)
                            : const Color(0xFF607D8B),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 7),
                    _StatusDot(active: online),
                    const Spacer(),
                    _RobotOnlineChip(online: mission.robotOnline),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF8A9691),
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
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
    final loadingWithoutData = weather.isLoading && snapshot == null;
    final unavailable = weather.errorMessage == '天氣暫不可用' && snapshot == null;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _IconBubble(
                icon: snapshot == null
                    ? Icons.cloud_queue_outlined
                    : _weatherIcon(snapshot.weatherCode),
                color: const Color(0xFF1E88A8),
                background: const Color(0xFFE6F5F8),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '天氣概況',
                      style: TextStyle(
                        color: Color(0xFF50605A),
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      loadingWithoutData
                          ? '天氣載入中'
                          : unavailable
                          ? '天氣暫不可用'
                          : snapshot?.conditionLabel ?? '天氣暫不可用',
                      style: const TextStyle(
                        color: Color(0xFF17211C),
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (weather.isLoading)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                )
              else
                Text(
                  snapshot == null
                      ? '--°'
                      : '${snapshot.temperatureC.round()}°',
                  style: const TextStyle(
                    color: Color(0xFF17211C),
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _WeatherMetric(
                  label: '體感',
                  value: snapshot == null
                      ? '--'
                      : '${snapshot.apparentTemperatureC.round()}°C',
                ),
              ),
              Expanded(
                child: _WeatherMetric(
                  label: '濕度',
                  value: snapshot == null
                      ? '--'
                      : '${snapshot.relativeHumidity}%',
                ),
              ),
              Expanded(
                child: _WeatherMetric(
                  label: '風速',
                  value: snapshot == null
                      ? '--'
                      : '${snapshot.windSpeedKmh.toStringAsFixed(1)} km/h',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            snapshot == null
                ? weather.errorMessage ?? 'Open-Meteo · 讀取目前作業位置'
                : 'Open-Meteo · ${_formatUpdateTime(snapshot.fetchedAt)} 更新',
            style: const TextStyle(
              color: Color(0xFF8A9691),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  static IconData _weatherIcon(int code) {
    return switch (code) {
      0 || 1 => Icons.wb_sunny_outlined,
      2 || 3 => Icons.cloud_outlined,
      45 || 48 => Icons.foggy,
      51 || 53 || 55 || 56 || 57 => Icons.grain_outlined,
      61 || 63 || 65 || 66 || 67 || 80 || 81 || 82 => Icons.water_drop_outlined,
      71 || 73 || 75 || 77 || 85 || 86 => Icons.ac_unit,
      95 || 96 || 99 => Icons.thunderstorm_outlined,
      _ => Icons.cloud_queue_outlined,
    };
  }
}

class _WeatherMetric extends StatelessWidget {
  const _WeatherMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF8A9691),
            fontSize: 11,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFF17211C),
            fontSize: 13,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _BatteryCard extends StatelessWidget {
  const _BatteryCard();

  @override
  Widget build(BuildContext context) {
    final mowerStatus = context.watch<MowerStatusProvider>().status;
    final battery = mowerStatus?.batteryPercent ?? 85;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '電量',
            style: TextStyle(
              color: Color(0xFF50605A),
              fontSize: 14,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 90,
                child: Text(
                  '${battery.round()}%',
                  style: const TextStyle(
                    color: Color(0xFF17211C),
                    fontSize: 34,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (battery / 100).clamp(0.0, 1.0),
                        minHeight: 10,
                        backgroundColor: const Color(0xFFE6ECE9),
                        color: const Color(0xFF168848),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '預估剩餘 2 小時 15 分鐘',
                      style: TextStyle(
                        color: Color(0xFF8A9691),
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MissionSummaryCard extends StatelessWidget {
  const _MissionSummaryCard();

  static const double _totalAreaM2 = 1200;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final zone = _selectedZone(mission);
    final progress = mission.coverageProgress.clamp(0.0, 1.0).toDouble();
    final completed = (_totalAreaM2 * progress).round();
    final remaining = (_totalAreaM2 - completed).round();
    final executing = mission.navStatus == NavMockStatus.executing;

    return _DashboardCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '目前任務',
            style: TextStyle(
              color: Color(0xFF50605A),
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _IconBubble(
                icon: Icons.yard_outlined,
                color: const Color(0xFF168848),
                background: const Color(0xFFE4F6EC),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      zone?.name ?? '尚未選擇區域',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF17211C),
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      executing ? '自動割草中' : mission.navStatusLabel(),
                      style: TextStyle(
                        color: executing
                            ? const Color(0xFF168848)
                            : const Color(0xFF607D8B),
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 72,
                height: 72,
                child: CustomPaint(
                  painter: _ProgressRingPainter(progress: progress),
                  child: Center(
                    child: Text(
                      '${(progress * 100).round()}%',
                      style: const TextStyle(
                        color: Color(0xFF17211C),
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _MissionMetric(
                label: '總草坪面積',
                value: '${_totalAreaM2.round()} m²',
              ),
              const _VerticalDivider(),
              _MissionMetric(label: '已完成', value: '$completed m²'),
              const _VerticalDivider(),
              _MissionMetric(label: '剩餘', value: '$remaining m²'),
            ],
          ),
        ],
      ),
    );
  }

  MissionZone? _selectedZone(MissionMockProvider mission) {
    for (final zone in mission.zones) {
      if (zone.id == mission.selectedZoneId) {
        return zone;
      }
    }
    return null;
  }
}

class _MissionMetric extends StatelessWidget {
  const _MissionMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF8A9691),
              fontSize: 11,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                color: Color(0xFF17211C),
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NextScheduleCard extends StatelessWidget {
  const _NextScheduleCard();

  @override
  Widget build(BuildContext context) {
    return const _InfoDashboardRow(
      icon: Icons.calendar_month_outlined,
      title: '下次排程',
      value: '後院區域',
      trailing: '明天 08:00',
    );
  }
}

class _DockStatusCard extends StatelessWidget {
  const _DockStatusCard();

  @override
  Widget build(BuildContext context) {
    return const _InfoDashboardRow(
      icon: Icons.ev_station_outlined,
      title: '充電座狀態',
      value: '已就緒',
      trailing: '›',
    );
  }
}

class _InfoDashboardRow extends StatelessWidget {
  const _InfoDashboardRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.trailing,
  });

  final IconData icon;
  final String title;
  final String value;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    return _DashboardCard(
      child: Row(
        children: [
          _IconBubble(
            icon: icon,
            color: const Color(0xFF263238),
            background: const Color(0xFFEFF3F1),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF50605A),
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: const TextStyle(
                    color: Color(0xFF168848),
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          Text(
            trailing,
            style: const TextStyle(
              color: Color(0xFF607D8B),
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x12000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: child,
      ),
    );
  }
}

class _IconBubble extends StatelessWidget {
  const _IconBubble({
    required this.icon,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: SizedBox(
        width: 42,
        height: 42,
        child: Icon(icon, color: color, size: 23),
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? const Color(0xFF168848) : const Color(0xFFB0BEC5),
        shape: BoxShape.circle,
      ),
      child: const SizedBox(width: 11, height: 11),
    );
  }
}

/// Robot liveness chip driven by the `/robot/online` heartbeat (distinct from
/// the app<->rosbridge link). Green = robot alive, grey = offline/unknown.
class _RobotOnlineChip extends StatelessWidget {
  const _RobotOnlineChip({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? const Color(0xFF167A4A) : const Color(0xFF90A4AE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: online ? const Color(0xFFE4F6EC) : const Color(0xFFF0F2F3),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            online ? Icons.smart_toy : Icons.smart_toy_outlined,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            online ? '機器人在線' : '機器人離線',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _VerticalDivider extends StatelessWidget {
  const _VerticalDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 42,
      margin: const EdgeInsets.symmetric(horizontal: 10),
      color: const Color(0xFFE6ECE9),
    );
  }
}

class _ScheduleTab extends StatelessWidget {
  const _ScheduleTab();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFF6F7F8),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          physics: const BouncingScrollPhysics(),
          children: const [
            Text(
              '排程',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            SizedBox(height: 16),
            _InfoDashboardRow(
              icon: Icons.calendar_month_outlined,
              title: '下一個任務',
              value: '後院區域',
              trailing: '明天 08:00',
            ),
            SizedBox(height: 10),
            _InfoDashboardRow(
              icon: Icons.repeat_outlined,
              title: '重複週期',
              value: '每週一、三、五',
              trailing: '08:00',
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreTab extends StatelessWidget {
  const _MoreTab();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return ColoredBox(
      color: const Color(0xFFF6F7F8),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          physics: const BouncingScrollPhysics(),
          children: [
            const Text(
              '更多',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 16),
            _DashboardCard(
              child: Column(
                children: [
                  _MoreActionRow(
                    icon: Icons.settings_outlined,
                    title: '機器人設定',
                    detail: mission.robotIp,
                    onTap: () =>
                        _showAppSheet(context, const _SettingsQuickSheet()),
                  ),
                  const Divider(height: 24),
                  _MoreActionRow(
                    icon: Icons.layers_outlined,
                    title: '地圖圖層',
                    detail: '工作區、禁入區、通道',
                    onTap: () =>
                        _showAppSheet(context, const _LayerToggleSheet()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            _DashboardCard(
              child: Column(
                children: [
                  _InfoRow(
                    icon: mission.rosConnected
                        ? Icons.radio_button_checked
                        : Icons.portable_wifi_off_outlined,
                    title: '資料來源',
                    detail: mission.rosConnected
                        ? 'ROS 即時資料'
                        : mission.mockDataEnabled
                        ? 'Mock fallback'
                        : '等待 ROS 真實資料',
                  ),
                  const _InfoRow(
                    icon: Icons.health_and_safety_outlined,
                    title: '安全狀態',
                    detail: 'Clear',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MoreActionRow extends StatelessWidget {
  const _MoreActionRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF167A4A)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF78909C),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Color(0xFF78909C)),
          ],
        ),
      ),
    );
  }
}

class MissionMapScreen extends StatefulWidget {
  const MissionMapScreen({super.key, required this.onManual});

  final VoidCallback onManual;

  @override
  State<MissionMapScreen> createState() => _MissionMapScreenState();
}

class _MissionMapScreenState extends State<MissionMapScreen> {
  final _canvasKey = GlobalKey<MissionMapCanvasState>();
  Offset? _popupOffset;
  bool _panelCollapsed = false;

  void _onLongPress(LongPressStartDetails details) {
    final positions =
        _canvasKey.currentState?.robotScreenPositions ?? {};
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

  void _dismissPopup() {
    context.read<RobotFleetProvider>().selectRobot(null);
    setState(() => _popupOffset = null);
  }

  Offset _clampedPopupOrigin(Offset robotPos, Size screenSize) {
    const popupW = 220.0;
    const popupH = 148.0;
    final left = (robotPos.dx - popupW / 2).clamp(8.0, screenSize.width - popupW - 8);
    final double top;
    if (robotPos.dy > screenSize.height * 0.55) {
      top = (robotPos.dy - popupH - 32).clamp(8.0, screenSize.height - popupH - 8);
    } else {
      top = (robotPos.dy + 32).clamp(8.0, screenSize.height - popupH - 8);
    }
    return Offset(left, top);
  }

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final fleet = context.watch<RobotFleetProvider>();
    final media = MediaQuery.of(context);
    final size = media.size;
    final isLandscape = size.width > size.height;
    final panelHeight = isLandscape
        ? math.min(size.height * 0.5, 220.0)
        : math.min(size.height * 0.43, 370.0);

    final collapsedH = 48.0 + media.padding.bottom;
    final effectivePanelH = _panelCollapsed ? collapsedH : panelHeight;

    final selectedRobot = fleet.selectedRobot;
    final popupOrigin = (_popupOffset != null && selectedRobot != null)
        ? _clampedPopupOrigin(_popupOffset!, size)
        : null;

    return Scaffold(
      body: GestureDetector(
        onLongPressStart: _onLongPress,
        onTap: () {
          if (fleet.selectedRobotId != null) _dismissPopup();
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: MissionMapCanvas(
                key: _canvasKey,
                mission: mission,
                robots: fleet.robots,
                selectedRobotId: fleet.selectedRobotId,
                bottomInset: effectivePanelH,
              ),
            ),
            Positioned(
              top: media.padding.top + 10,
              left: 12,
              right: 76,
              child: const TopStatusPill(),
            ),
            Positioned(
              top: media.padding.top + 78,
              right: 12,
              child: _MapActionRail(
                onAdd: () => _showAppSheet(context, const AddObjectSheet()),
                onLayers: () =>
                    _showAppSheet(context, const _LayerToggleSheet()),
                onSettings: () =>
                    _showAppSheet(context, const _SettingsQuickSheet()),
                onManual: widget.onManual,
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                height: effectivePanelH,
                child: _MissionBottomPanel(
                  isCollapsed: _panelCollapsed,
                  onToggle: () =>
                      setState(() => _panelCollapsed = !_panelCollapsed),
                ),
              ),
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

String _formatUpdateTime(DateTime value) {
  final diff = DateTime.now().difference(value);
  if (diff.inMinutes < 1) {
    return '剛剛';
  }
  if (diff.inHours < 1) {
    return '${diff.inMinutes} 分鐘前';
  }
  if (diff.inHours < 24) {
    return '${diff.inHours} 小時前';
  }
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

class _MowerMiniPainter extends CustomPainter {
  const _MowerMiniPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final shadowPaint = Paint()..color = const Color(0x26000000);
    final bodyPaint = Paint()..color = const Color(0xFFE7ECE8);
    final trimPaint = Paint()..color = const Color(0xFF223029);
    final greenPaint = Paint()..color = const Color(0xFF168848);
    final orangePaint = Paint()..color = const Color(0xFFE26F22);

    canvas.drawOval(
      Rect.fromLTWH(size.width * 0.1, size.height * 0.68, size.width * 0.76, 9),
      shadowPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.12,
          size.height * 0.28,
          size.width * 0.68,
          size.height * 0.34,
        ),
        const Radius.circular(16),
      ),
      bodyPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          size.width * 0.28,
          size.height * 0.2,
          size.width * 0.34,
          size.height * 0.26,
        ),
        const Radius.circular(10),
      ),
      Paint()..color = const Color(0xFFB8C8C2),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.2, size.height * 0.55, 24, 13),
        const Radius.circular(8),
      ),
      trimPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.58, size.height * 0.52, 26, 15),
        const Radius.circular(8),
      ),
      trimPaint,
    );
    canvas.drawCircle(
      Offset(size.width * 0.73, size.height * 0.6),
      7,
      greenPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width * 0.39, size.height * 0.16, 17, 7),
        const Radius.circular(4),
      ),
      orangePaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MowerMiniPainter oldDelegate) => false;
}

class _ProgressRingPainter extends CustomPainter {
  const _ProgressRingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 5;
    final backgroundPaint = Paint()
      ..color = const Color(0xFFE6ECE9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    final progressPaint = Paint()
      ..color = const Color(0xFF168848)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, radius, backgroundPaint);
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      math.pi * 2 * progress,
      false,
      progressPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ProgressRingPainter oldDelegate) {
    return progress != oldDelegate.progress;
  }
}

class _MapActionRail extends StatelessWidget {
  const _MapActionRail({
    required this.onAdd,
    required this.onLayers,
    required this.onSettings,
    required this.onManual,
  });

  final VoidCallback onAdd;
  final VoidCallback onLayers;
  final VoidCallback onSettings;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundIconButton(
          icon: Icons.add,
          tooltip: '新增物件',
          color: const Color(0xFF1384E8),
          onTap: onAdd,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.layers_outlined,
          tooltip: '圖層',
          onTap: onLayers,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.settings_outlined,
          tooltip: '設定',
          onTap: onSettings,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.sports_esports_outlined,
          tooltip: '手動控制',
          onTap: onManual,
        ),
      ],
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? const Color(0xFF263238);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.94),
        shape: const CircleBorder(),
        elevation: 7,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: foreground, size: 26),
          ),
        ),
      ),
    );
  }
}

class _MissionBottomPanel extends StatelessWidget {
  const _MissionBottomPanel({
    required this.isCollapsed,
    required this.onToggle,
  });

  final bool isCollapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Tappable handle row
              GestureDetector(
                onTap: onToggle,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 44,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFD0D7DA),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: isCollapsed ? 0.5 : 0,
                        duration: const Duration(milliseconds: 280),
                        curve: Curves.easeInOut,
                        child: const Icon(
                          Icons.keyboard_arrow_down,
                          size: 18,
                          color: Color(0xFFB0BEC5),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (!isCollapsed) ...[
                const MissionModeBar(),
                const SizedBox(height: 10),
                Expanded(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _ModePanel(
                        key: ValueKey(mission.selectedMode),
                        mode: mission.selectedMode,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModePanel extends StatelessWidget {
  const _ModePanel({super.key, required this.mode});

  final MissionMode mode;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case MissionMode.objects:
        return const MapObjectsSheet();
      case MissionMode.record:
        return const RecordControlSheet();
      case MissionMode.plan:
        return const PlanningControlSheet();
      case MissionMode.run:
        return const ExecutionControlSheet();
      case MissionMode.logs:
        return const OperationLogSheet();
    }
  }
}

class _LayerToggleSheet extends StatelessWidget {
  const _LayerToggleSheet();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 18),
            const Text(
              '圖層',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            _LayerSwitch(
              title: '工作區',
              value: mission.layers.zones,
              onChanged: (value) => mission.updateLayer(zones: value),
            ),
            _LayerSwitch(
              title: '禁入區',
              value: mission.layers.risks,
              onChanged: (value) => mission.updateLayer(risks: value),
            ),
            _LayerSwitch(
              title: '通道',
              value: mission.layers.channels,
              onChanged: (value) => mission.updateLayer(channels: value),
            ),
            _LayerSwitch(
              title: '覆蓋路徑',
              value: mission.layers.coverage,
              onChanged: (value) => mission.updateLayer(coverage: value),
            ),
            _LayerSwitch(
              title: '風險線段',
              value: mission.layers.invalidSegments,
              onChanged: (value) => mission.updateLayer(invalidSegments: value),
            ),
          ],
        ),
      ),
    );
  }
}

class _LayerSwitch extends StatelessWidget {
  const _LayerSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SettingsQuickSheet extends StatefulWidget {
  const _SettingsQuickSheet();

  @override
  State<_SettingsQuickSheet> createState() => _SettingsQuickSheetState();
}

class _SettingsQuickSheetState extends State<_SettingsQuickSheet> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  bool _initialized = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _ipController.text = context.read<MissionMockProvider>().robotIp;
    _initialized = true;
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 18),
            const Text(
              '設定',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _ipController,
                keyboardType: TextInputType.text,
                validator: (value) =>
                    RosbridgeService.validateRobotIp(value ?? ''),
                decoration: const InputDecoration(
                  labelText: '機器人 IP',
                  hintText: '192.168.1.100',
                  prefixIcon: Icon(Icons.router_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : () => _saveRobotIp(context),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(_saving ? '儲存中' : '儲存並重連'),
              ),
            ),
            const SizedBox(height: 16),
            _InfoRow(
              icon: Icons.link_outlined,
              title: 'rosbridge',
              detail: mission.rosbridgeUrl,
            ),
            _InfoRow(
              icon: Icons.storage_outlined,
              title: '資料來源',
              detail: mission.rosConnected
                  ? 'ROS 即時資料'
                  : mission.mockDataEnabled
                  ? 'Mock fallback'
                  : '等待 ROS 真實資料',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Mock 資料',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                mission.mockDataEnabled
                    ? 'rosbridge 未連線時使用 demo fallback'
                    : '關閉 demo，畫面只吃 ROS 真實 topic',
                style: const TextStyle(
                  color: Color(0xFF78909C),
                  fontWeight: FontWeight.w700,
                ),
              ),
              value: mission.mockDataEnabled,
              onChanged: (value) {
                unawaited(mission.setMockDataEnabled(value));
              },
            ),
            _InfoRow(icon: Icons.map_outlined, title: '底圖模式', detail: '灰底任務地圖'),
            _InfoRow(
              icon: Icons.satellite_alt_outlined,
              title: '衛星圖',
              detail: '等待 API 串接',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveRobotIp(BuildContext context) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final mission = context.read<MissionMockProvider>();
    final error = await mission.updateRobotIp(_ipController.text);
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('機器人 IP 已更新')));
    navigator.pop();
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
          Icon(icon, color: const Color(0xFF167A4A)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFF78909C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFD0D7DA),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
