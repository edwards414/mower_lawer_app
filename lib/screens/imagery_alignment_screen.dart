import 'dart:async';

import 'package:flutter/material.dart';

import '../models/geo_anchor.dart';
import '../providers/mission_mock_provider.dart';
import '../services/google_map_tiles.dart';
import '../services/imagery_offset_store.dart';
import '../utils/app_icons.dart';
import '../widgets/satellite_map_view.dart';

/// Lines Google's satellite photo up with where things really are, for the
/// site on the map. Satellite photos are placed a metre or few off; the NLSC
/// aerial survey (laid faintly over it) and the zones the robot drove with
/// RTK are the truth. The arrows move Google's photo 0.1 m a tap (held, it
/// keeps going); saving applies it to the map for this site.
class ImageryAlignmentScreen extends StatefulWidget {
  const ImageryAlignmentScreen({
    super.key,
    required this.mission,
    this.store,
    this.googleTiles,
  });

  final MissionMockProvider mission;

  /// Injected for tests; by default the shared ones.
  final ImageryOffsetStore? store;
  final GoogleMapTiles? googleTiles;

  @override
  State<ImageryAlignmentScreen> createState() => _ImageryAlignmentScreenState();
}

class _ImageryAlignmentScreenState extends State<ImageryAlignmentScreen> {
  ImageryOffsetStore get _store => widget.store ?? ImageryOffsetStore.shared;

  /// The site being aligned: the map's, when the page opened.
  late final GeoAnchor? _site = widget.mission.mapGeoAnchor;

  ImageryOffset? _saved;
  ImageryOffset _offset = ImageryOffset.zero;
  double _compare = 0.5;
  Timer? _repeat;

  @override
  void initState() {
    super.initState();
    final site = _site;
    if (site != null) {
      _store.load(site).then((saved) {
        if (!mounted) return;
        setState(() {
          _saved = saved;
          _offset = saved;
        });
      });
    }
  }

  @override
  void dispose() {
    _repeat?.cancel();
    super.dispose();
  }

  void _nudge(double east, double north) =>
      setState(() => _offset = _offset.moved(east, north));

  /// Held: keeps moving, about 1 m a second.
  void _startRepeat(double east, double north) {
    _repeat?.cancel();
    _repeat = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _nudge(east, north),
    );
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  Future<void> _save() async {
    final site = _site;
    if (site == null) return;
    await _store.save(site, _offset);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _offset.isZero ? '已改回不偏移' : '已儲存：${describeOffset(_offset)}',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final site = _site;
    return Scaffold(
      appBar: AppBar(title: const Text('衛星圖對位')),
      body: site == null
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  '地圖還沒有 GPS 位置。連上割草機、地圖有了位置後再來對位。',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListenableBuilder(
                    listenable: widget.mission,
                    builder: (context, _) => SatelliteMapView(
                      mission: widget.mission,
                      anchor: site,
                      googleTiles: widget.googleTiles,
                      googleOffset: _offset,
                      nlscCompare: _compare,
                      offsetStore: _store,
                    ),
                  ),
                ),
                _Panel(
                  offset: _offset,
                  changed: _saved != null && _offset != _saved,
                  compare: _compare,
                  onCompare: (v) => setState(() => _compare = v),
                  onNudge: _nudge,
                  onHoldStart: _startRepeat,
                  onHoldEnd: _stopRepeat,
                  onReset: () => setState(() => _offset = ImageryOffset.zero),
                  onSave: _saved == null ? null : _save,
                ),
              ],
            ),
    );
  }
}

/// "往東 1.4 m · 往北 1.1 m", or "不偏移".
String describeOffset(ImageryOffset o) {
  if (o.isZero) return '不偏移';
  String part(double v, String plus, String minus) =>
      '往${v >= 0 ? plus : minus} ${v.abs().toStringAsFixed(1)} m';
  return [
    if (o.eastM != 0) part(o.eastM, '東', '西'),
    if (o.northM != 0) part(o.northM, '北', '南'),
  ].join(' · ');
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.offset,
    required this.changed,
    required this.compare,
    required this.onCompare,
    required this.onNudge,
    required this.onHoldStart,
    required this.onHoldEnd,
    required this.onReset,
    required this.onSave,
  });

  final ImageryOffset offset;
  final bool changed;
  final double compare;
  final ValueChanged<double> onCompare;
  final void Function(double east, double north) onNudge;
  final void Function(double east, double north) onHoldStart;
  final VoidCallback onHoldEnd;
  final VoidCallback onReset;
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    const step = ImageryOffset.stepM;
    Widget arrow(IconData icon, String tip, double east, double north) =>
        _ArrowButton(
          icon: icon,
          tooltip: tip,
          onTap: () => onNudge(east * step, north * step),
          onHoldStart: () => onHoldStart(east * step, north * step),
          onHoldEnd: onHoldEnd,
        );

    return Material(
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                '用箭頭移動 Google 衛星圖，對齊淡淡疊在上面的國土測繪中心航照'
                '（位置最準），或割草機開過的區域邊界。請對地面的道路、標線、'
                '草地邊緣，不要對屋頂：衛星照片裡的高樓會歪一邊。',
                style: TextStyle(fontSize: 13, height: 1.4),
              ),
              Row(
                children: [
                  const Text('對照航照'),
                  Expanded(
                    child: Slider(
                      value: compare,
                      onChanged: onCompare,
                      semanticFormatterCallback: (v) =>
                          '航照 ${(v * 100).round()}%',
                    ),
                  ),
                ],
              ),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        arrow(AppIcons.arrowUp, '往北', 0, 1),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            arrow(AppIcons.arrowLeft, '往西', -1, 0),
                            const SizedBox(width: 56),
                            arrow(AppIcons.arrowRight, '往東', 1, 0),
                          ],
                        ),
                        arrow(AppIcons.arrowDown, '往南', 0, -1),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          describeOffset(offset),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          '點一下 0.1 m，按住會一直移動',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton(
                          onPressed: offset.isZero ? null : onReset,
                          child: const Text('歸零'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton(
                          onPressed: onSave,
                          child: Text(changed ? '儲存' : '完成'),
                        ),
                      ],
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

class _ArrowButton extends StatelessWidget {
  const _ArrowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        onLongPressCancel: onHoldEnd,
        child: Container(
          width: 52,
          height: 52,
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF3F0),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, size: 26),
        ),
      ),
    );
  }
}
