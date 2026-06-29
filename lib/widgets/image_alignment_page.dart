import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import 'mission_map_canvas.dart';

/// Full-screen page where the user drags / pinch-zooms / rotates the uploaded
/// image mask to align it onto the robot-collected freespace shown on the map.
///
/// The placement is held locally while interacting (no path is computed) and
/// only committed to [MissionMockProvider] when the user confirms.
class ImageAlignmentPage extends StatefulWidget {
  const ImageAlignmentPage({super.key, required this.mission});

  final MissionMockProvider mission;

  @override
  State<ImageAlignmentPage> createState() => _ImageAlignmentPageState();
}

enum _DragMode { none, translate, rotate, scaleCorner }

class _ImageAlignmentPageState extends State<ImageAlignmentPage> {
  final GlobalKey<MissionMapCanvasState> _canvasKey = GlobalKey();

  late ImageMissionDraft _draft;
  late ImageMissionPlacement _placement;
  late MapPoint _startPixel;
  Rect? _worldBoundsOverride;
  // Initial fit, used to clamp how far the wheel can zoom the view.
  Rect? _baseBounds;

  ui.Image? _overlayImage;

  // Active drag interaction (Word-style handles, single-pointer/mouse).
  _DragMode _mode = _DragMode.none;
  ImageMissionPlacement _startPlacement = const ImageMissionPlacement(
    mapAnchor: MapPoint(0, 0),
  );
  Offset _startLocal = Offset.zero;
  MapPoint _startAnchor = const MapPoint(0, 0);
  // scale-by-corner: the opposite corner stays fixed
  MapPoint _scaleFixedWorld = const MapPoint(0, 0);
  double _scaleStartDist = 1.0;
  // rotate-by-handle: rotate about the image centre
  MapPoint _rotCenterWorld = const MapPoint(0, 0);
  double _rotStartAngle = 0.0;

  @override
  void initState() {
    super.initState();
    // The caller (sheet) calls initImageMissionPlacement() before pushing, so
    // placement/startPose are usually set. Fall back defensively without
    // mutating the provider during build.
    final draft = widget.mission.imageMissionDraft!;
    _draft = draft;
    _placement =
        draft.placement ??
        ImageMissionPlacement(mapAnchor: widget.mission.robotPosition);
    _startPixel =
        draft.startPose?.point ??
        MapPoint(draft.width / 2, draft.height / 2);
    _buildOverlayImage(draft);
    _worldBoundsOverride = _computeFrozenBounds();
    _baseBounds = _worldBoundsOverride;
  }

  @override
  void dispose() {
    _overlayImage?.dispose();
    super.dispose();
  }

  Future<void> _buildOverlayImage(ImageMissionDraft draft) async {
    final w = draft.width;
    final h = draft.height;
    final pixels = Uint8List(w * h * 4);
    final risk = draft.riskMask;
    for (var i = 0; i < w * h; i += 1) {
      final idx = i * 4;
      if (risk != null && i < risk.length && risk[i] == 255) {
        pixels[idx] = 0xE5;
        pixels[idx + 1] = 0x39;
        pixels[idx + 2] = 0x35;
        pixels[idx + 3] = 0xCC; // red, semi-transparent
      } else if (draft.freeMask[i] == 255) {
        pixels[idx] = 0x2E;
        pixels[idx + 1] = 0xC8;
        pixels[idx + 2] = 0x6E;
        pixels[idx + 3] = 0x9C; // green, semi-transparent
      }
      // else fully transparent
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() => _overlayImage = image);
  }

  ImageAlignmentOverlay? _overlay() {
    final image = _overlayImage;
    if (image == null) {
      return null;
    }
    return ImageAlignmentOverlay(
      image: image,
      imageWidth: _draft.width,
      imageHeight: _draft.height,
      baseResolutionM: _draft.resolutionM,
      startPixel: _startPixel,
      placement: _placement,
    );
  }

  Rect _computeFrozenBounds() {
    final rects = <Rect>[];
    final fs = widget.mission.freeSpaceLayer;
    if (fs != null) {
      rects.add(
        Rect.fromLTWH(
          fs.originX,
          fs.originY,
          fs.width * fs.resolution,
          fs.height * fs.resolution,
        ),
      );
    }
    final overlay = ImageAlignmentOverlay(
      image: _placeholderImage,
      imageWidth: _draft.width,
      imageHeight: _draft.height,
      baseResolutionM: _draft.resolutionM,
      startPixel: _startPixel,
      placement: _placement,
    );
    rects.add(overlay.worldBounds());
    var bounds = rects.first;
    for (final r in rects.skip(1)) {
      bounds = bounds.expandToInclude(r);
    }
    final margin = math.max(bounds.width, bounds.height) * 0.2 + 1.0;
    return Rect.fromLTRB(
      bounds.left - margin,
      bounds.top - margin,
      bounds.right + margin,
      bounds.bottom + margin,
    );
  }

  // A 1×1 transparent image only used so worldBounds() can be computed before
  // the real overlay image finishes decoding (worldBounds ignores pixels).
  static final ui.Image _placeholderImage = _makePlaceholder();
  static ui.Image _makePlaceholder() {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    return recorder.endRecording().toImageSync(1, 1);
  }

  void _onPanStart(DragStartDetails details) {
    final proj = _canvasKey.currentState?.lastProjection;
    final overlay = _overlay();
    if (proj == null || overlay == null) {
      _mode = _DragMode.none;
      return;
    }
    final local = details.localPosition;
    _startPlacement = _placement;
    _startLocal = local;

    final corners = alignmentCornerScreens(overlay, proj.project);
    final rotateHandle = alignmentRotateHandleScreen(overlay, proj.project);

    // 1) rotate handle, 2) a corner, 3) inside the quad → translate.
    if ((local - rotateHandle).distance <= 22) {
      _mode = _DragMode.rotate;
      _rotCenterWorld = overlay.centerWorld;
      final centerScreen = proj.project(_rotCenterWorld);
      _rotStartAngle = (local - centerScreen).direction;
      return;
    }
    var best = -1;
    var bestDist = 26.0;
    for (var i = 0; i < 4; i += 1) {
      final d = (local - corners[i]).distance;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    if (best >= 0) {
      final fixed = overlay.corner((best + 2) % 4);
      final dist = _distWorld(overlay.corner(best), fixed);
      if (dist > 1e-6) {
        _mode = _DragMode.scaleCorner;
        _scaleFixedWorld = fixed;
        _scaleStartDist = dist;
        return;
      }
    }
    if (_pointInQuad(local, corners)) {
      _mode = _DragMode.translate;
      _startAnchor = _placement.mapAnchor;
    } else {
      _mode = _DragMode.none;
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final proj = _canvasKey.currentState?.lastProjection;
    if (proj == null || _mode == _DragMode.none) {
      return;
    }
    final local = details.localPosition;
    switch (_mode) {
      case _DragMode.translate:
        final dScreen = local - _startLocal;
        setState(() {
          _placement = _startPlacement.copyWith(
            mapAnchor: MapPoint(
              _startAnchor.x + dScreen.dx / proj.scale,
              _startAnchor.y + dScreen.dy / proj.scale,
            ),
          );
        });
        break;
      case _DragMode.scaleCorner:
        final target = proj.unproject(local);
        final sStart = _startPlacement.mapScale;
        var f = _distWorld(target, _scaleFixedWorld) / _scaleStartDist;
        f = f.clamp(0.2 / sStart, 8.0 / sStart).toDouble();
        final o = _scaleFixedWorld;
        final a = _startPlacement.mapAnchor;
        setState(() {
          _placement = _startPlacement.copyWith(
            mapScale: sStart * f,
            mapAnchor: MapPoint(
              o.x + f * (a.x - o.x),
              o.y + f * (a.y - o.y),
            ),
          );
        });
        break;
      case _DragMode.rotate:
        final centerScreen = proj.project(_rotCenterWorld);
        final dPhi = (local - centerScreen).direction - _rotStartAngle;
        final c = _rotCenterWorld;
        final a = _startPlacement.mapAnchor;
        final cosD = math.cos(dPhi);
        final sinD = math.sin(dPhi);
        final ax = a.x - c.x;
        final ay = a.y - c.y;
        setState(() {
          _placement = _startPlacement.copyWith(
            mapRotationRad: _startPlacement.mapRotationRad + dPhi,
            mapAnchor: MapPoint(
              c.x + cosD * ax - sinD * ay,
              c.y + sinD * ax + cosD * ay,
            ),
          );
        });
        break;
      case _DragMode.none:
        break;
    }
  }

  void _onPanEnd(DragEndDetails details) {
    _mode = _DragMode.none;
  }

  double _distWorld(MapPoint a, MapPoint b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  bool _pointInQuad(Offset p, List<Offset> q) {
    bool side(Offset a, Offset b) =>
        (b.dx - a.dx) * (p.dy - a.dy) - (b.dy - a.dy) * (p.dx - a.dx) >= 0;
    final s0 = side(q[0], q[1]);
    final s1 = side(q[1], q[2]);
    final s2 = side(q[2], q[3]);
    final s3 = side(q[3], q[0]);
    return s0 == s1 && s1 == s2 && s2 == s3;
  }

  void _onTapUp(TapUpDetails details) {
    final proj = _canvasKey.currentState?.lastProjection;
    final overlay = _overlay();
    if (proj == null || overlay == null) {
      return;
    }
    final worldTap = proj.unproject(details.localPosition);
    final pixel = overlay.pixelOf(worldTap);
    final clamped = MapPoint(
      pixel.x.clamp(0.0, (_draft.width - 1).toDouble()).toDouble(),
      pixel.y.clamp(0.0, (_draft.height - 1).toDouble()).toDouble(),
    );
    // Keep anchor = tapped world point so the image does not move; only the
    // start pivot pixel changes.
    setState(() {
      _startPixel = clamped;
      _placement = _placement.copyWith(mapAnchor: worldTap);
    });
  }

  void _confirm() {
    widget.mission.updateImageMissionStartPose(
      ImageMissionStartPose(point: _startPixel, headingRad: 0.0),
    );
    widget.mission.updateImageMissionPlacement(_placement);
    Navigator.of(context).pop(true);
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('操作說明'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _HelpRow(Icons.open_with, '拖曳圖片 = 移動位置'),
            _HelpRow(Icons.crop_square, '拖四角方塊 = 等比例縮放'),
            _HelpRow(Icons.rotate_right, '拖頂端圓點 = 旋轉'),
            _HelpRow(Icons.place, '點一下圖片 = 設定起點（綠點）'),
            _HelpRow(Icons.zoom_in, '＋／－ 或滾輪 = 縮放整張地圖'),
            _HelpRow(Icons.restart_alt, '重設 = 還原圖片位置'),
            _HelpRow(Icons.check_circle, '確認對齊 = 完成，回到送出'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  void _resetPlacement() {
    widget.mission.resetImageMissionPlacement();
    final draft = widget.mission.imageMissionDraft!;
    setState(() {
      _placement =
          draft.placement ??
          ImageMissionPlacement(mapAnchor: widget.mission.robotPosition);
      _startPixel =
          draft.startPose?.point ??
          MapPoint(draft.width / 2, draft.height / 2);
      _worldBoundsOverride = _computeFrozenBounds();
      _baseBounds = _worldBoundsOverride;
    });
  }

  /// Mouse-wheel / trackpad scroll zooms the whole map view about the cursor.
  void _onScroll(PointerScrollEvent event) {
    final proj = _canvasKey.currentState?.lastProjection;
    if (proj == null) {
      return;
    }
    // Scroll up (dy < 0) → zoom in, down → zoom out, about the cursor.
    final focus = proj.unproject(event.localPosition);
    _zoomViewBy(math.pow(1.0015, -event.scrollDelta.dy).toDouble(), focus);
  }

  /// +/- buttons: fixed-ratio zoom about the current view centre.
  void _zoomViewByButton(double z) {
    final r = _worldBoundsOverride;
    if (r == null) {
      return;
    }
    _zoomViewBy(z, MapPoint(r.center.dx, r.center.dy));
  }

  /// Zoom the framed world rect by [z] (z>1 = zoom in) about [focus],
  /// clamped to 8× in / 4× out of the initial fit.
  void _zoomViewBy(double z, MapPoint focus) {
    final r = _worldBoundsOverride;
    final base = _baseBounds;
    if (r == null || base == null) {
      return;
    }
    final minW = base.width / 8.0;
    final maxW = base.width * 4.0;
    final targetW = r.width / z;
    if (targetW < minW) {
      z = r.width / minW;
    } else if (targetW > maxW) {
      z = r.width / maxW;
    }
    if ((z - 1.0).abs() < 1e-6) {
      return;
    }
    setState(() {
      _worldBoundsOverride = Rect.fromLTRB(
        focus.x - (focus.x - r.left) / z,
        focus.y - (focus.y - r.top) / z,
        focus.x + (r.right - focus.x) / z,
        focus.y + (r.bottom - focus.y) / z,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final overlay = _overlay();
    return Scaffold(
      backgroundColor: const Color(0xFF101418),
      body: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            _onScroll(event);
          }
        },
        child: Stack(
          children: [
          Positioned.fill(
            child: MissionMapCanvas(
              key: _canvasKey,
              mission: widget.mission,
              bottomInset: 0,
              showScalePill: false,
              alignmentOverlay: overlay,
              worldBoundsOverride: _worldBoundsOverride,
            ),
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onTapUp: _onTapUp,
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                _TopBar(
                  onClose: () => Navigator.of(context).pop(false),
                  onInfo: _showHelp,
                ),
                const Spacer(),
                if (overlay == null) const _HintCard(),
                const SizedBox(height: 10),
                _BottomBar(onReset: _resetPlacement, onConfirm: _confirm),
              ],
            ),
          ),
          Positioned(
            right: 14,
            bottom: 120,
            child: _ZoomButtons(
              onZoomIn: () => _zoomViewByButton(1.25),
              onZoomOut: () => _zoomViewByButton(1 / 1.25),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _ZoomButtons extends StatelessWidget {
  const _ZoomButtons({required this.onZoomIn, required this.onZoomOut});

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _button(Icons.add, onZoomIn),
        const SizedBox(height: 10),
        _button(Icons.remove, onZoomOut),
      ],
    );
  }

  Widget _button(IconData icon, VoidCallback onTap) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 46,
          height: 46,
          child: Icon(icon, color: Colors.white, size: 26),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.onClose, required this.onInfo});

  final VoidCallback onClose;
  final VoidCallback onInfo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
          const Text(
            '在地圖上對齊',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onInfo,
            tooltip: '操作說明',
            icon: const Icon(Icons.info_outline, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _HintCard extends StatelessWidget {
  const _HintCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        '載入圖層中…',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _HelpRow extends StatelessWidget {
  const _HelpRow(this.icon, this.text);

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF167A4A)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 14, height: 1.25)),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.onReset, required this.onConfirm});

  final VoidCallback onReset;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: SizedBox(
        height: 48,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.restart_alt, color: Colors.white),
                label: const Text('重設', style: TextStyle(color: Colors.white)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white54),
                ),
              ),
            ),
            Align(
              alignment: Alignment.center,
              child: FilledButton.icon(
                onPressed: onConfirm,
                icon: const Icon(Icons.check),
                label: const Text('確認對齊'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
