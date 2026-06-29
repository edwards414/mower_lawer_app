import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../services/image_mission_processor.dart';
import 'image_alignment_page.dart';

class ImageMissionSheet extends StatefulWidget {
  const ImageMissionSheet({super.key});

  @override
  State<ImageMissionSheet> createState() => _ImageMissionSheetState();
}

class _ImageMissionSheetState extends State<ImageMissionSheet> {
  final _picker = ImagePicker();
  final _processor = const ImageMissionProcessor();
  int _step = 0;
  double _previewZoom = 1.0;
  bool _picking = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context.read<MissionMockProvider>().imageMissionDraft != null &&
        _step == 0) {
      _step = 1;
    }
  }

  Future<void> _pickImage() async {
    setState(() => _picking = true);
    try {
      final image = await _picker.pickImage(source: ImageSource.gallery);
      if (image == null) {
        return;
      }
      final bytes = await image.readAsBytes();
      final draft = _processor.decodeDraft(bytes, sourceName: image.name);
      if (!mounted) {
        return;
      }
      context.read<MissionMockProvider>().setImageMissionDraft(draft);
      setState(() {
        _step = 1;
        _previewZoom = 1.0;
      });
    } on ImageMissionProcessingException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
      }
    } finally {
      if (mounted) {
        setState(() => _picking = false);
      }
    }
  }

  Future<void> _openAlignment(MissionMockProvider mission) async {
    // Compute default placement/start (safe here — a tap handler, not build),
    // then open the full-screen map alignment page.
    mission.initImageMissionPlacement();
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => ImageAlignmentPage(mission: mission),
      ),
    );
    if (mounted) {
      setState(() {});
    }
  }

  void _paintRisk(ImageMissionDraft draft, MapPoint point) {
    final mask = Uint8List.fromList(
      draft.riskMask ??
          ImageMissionProcessor.emptyMask(draft.width, draft.height),
    );
    const radiusPx = 10;
    final cx = point.x.round();
    final cy = point.y.round();
    for (
      var y = math.max(0, cy - radiusPx);
      y <= math.min(draft.height - 1, cy + radiusPx);
      y += 1
    ) {
      for (
        var x = math.max(0, cx - radiusPx);
        x <= math.min(draft.width - 1, cx + radiusPx);
        x += 1
      ) {
        final dx = x - cx;
        final dy = y - cy;
        if (dx * dx + dy * dy <= radiusPx * radiusPx) {
          mask[y * draft.width + x] = 255;
        }
      }
    }
    context.read<MissionMockProvider>().updateImageMissionRiskMask(mask);
  }

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final draft = mission.imageMissionDraft;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 18,
          right: 18,
          top: 12,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD0D7DA),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '圖片任務',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  if (draft != null)
                    TextButton.icon(
                      onPressed: mission.clearImageMissionDraft,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('清除'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              _StepPills(currentStep: _step),
              const SizedBox(height: 14),
              if (draft == null || _step == 0)
                _PickStep(picking: _picking, onPick: _pickImage)
              else if (_step == 1)
                _ThresholdStep(
                  draft: draft,
                  onThresholdChanged: mission.updateImageMissionThreshold,
                  onNext: () => setState(() => _step = 2),
                )
              else if (_step == 2)
                _ScaleStep(
                  draft: draft,
                  previewZoom: _previewZoom,
                  onResolutionChanged: mission.updateImageMissionResolution,
                  onPreviewZoomChanged: (value) =>
                      setState(() => _previewZoom = value),
                  onBack: () => setState(() => _step = 1),
                  onNext: draft.resolutionM > 0
                      ? () => setState(() => _step = 3)
                      : null,
                )
              else if (_step == 3)
                _AlignStep(
                  draft: draft,
                  onOpenAlign: () => _openAlignment(mission),
                  onBack: () => setState(() => _step = 2),
                  onNext: draft.placement == null
                      ? null
                      : () => setState(() => _step = 4),
                )
              else
                _RiskAndSubmitStep(
                  draft: draft,
                  previewZoom: _previewZoom,
                  rosConnected: mission.rosConnected,
                  onRiskPoint: (point) => _paintRisk(draft, point),
                  onClearRisk: mission.clearImageMissionRiskMask,
                  onBack: () => setState(() => _step = 3),
                  onSubmit: mission.submitImageMissionDraft,
                  onExecute: draft.submitted
                      ? () {
                          mission.startExecution();
                          Navigator.of(context).pop();
                        }
                      : null,
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _StepPills extends StatelessWidget {
  const _StepPills({required this.currentStep});

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    const labels = ['選圖', '黑白', '縮放', '對齊', '送出'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i += 1) ...[
          Expanded(
            child: Container(
              height: 30,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: i <= currentStep
                    ? const Color(0xFFE4F6EC)
                    : const Color(0xFFF0F2F3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                labels[i],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: i <= currentStep
                      ? const Color(0xFF167A4A)
                      : const Color(0xFF78909C),
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          if (i != labels.length - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }
}

class _PickStep extends StatelessWidget {
  const _PickStep({required this.picking, required this.onPick});

  final bool picking;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 190,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFFF4F7F5),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFD8E3DC)),
            ),
            child: const Icon(
              Icons.image_search_outlined,
              size: 56,
              color: Color(0xFF167A4A),
            ),
          ),
        ),
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: picking ? null : onPick,
          icon: picking
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.photo_library_outlined),
          label: Text(picking ? '讀取中' : '選擇圖片'),
        ),
      ],
    );
  }
}

class _ThresholdStep extends StatelessWidget {
  const _ThresholdStep({
    required this.draft,
    required this.onThresholdChanged,
    required this.onNext,
  });

  final ImageMissionDraft draft;
  final ValueChanged<int> onThresholdChanged;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MaskPreview(draft: draft, height: 250),
        const SizedBox(height: 10),
        Row(
          children: [
            const Text(
              'Threshold',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            Text(
              draft.threshold.toString(),
              style: const TextStyle(
                color: Color(0xFF167A4A),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Slider(
          value: draft.threshold.toDouble(),
          min: 0,
          max: 255,
          divisions: 255,
          onChanged: (value) => onThresholdChanged(value.round()),
        ),
        FilledButton.icon(
          onPressed: draft.freeCellCount == 0 ? null : onNext,
          icon: const Icon(Icons.tune),
          label: const Text('下一步'),
        ),
      ],
    );
  }
}

class _ScaleStep extends StatelessWidget {
  const _ScaleStep({
    required this.draft,
    required this.previewZoom,
    required this.onResolutionChanged,
    required this.onPreviewZoomChanged,
    required this.onBack,
    required this.onNext,
  });

  final ImageMissionDraft draft;
  final double previewZoom;
  final ValueChanged<double> onResolutionChanged;
  final ValueChanged<double> onPreviewZoomChanged;
  final VoidCallback onBack;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MaskPreview(draft: draft, height: 250, previewScale: previewZoom),
        const SizedBox(height: 10),
        Row(
          children: [
            const Text('地圖比例', style: TextStyle(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(
              '${draft.resolutionM.toStringAsFixed(3)} m/px',
              style: const TextStyle(
                color: Color(0xFF167A4A),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Slider(
          value: draft.resolutionM.clamp(0.005, 0.5).toDouble(),
          min: 0.005,
          max: 0.5,
          divisions: 99,
          onChanged: onResolutionChanged,
        ),
        Row(
          children: [
            const Text('預覽放大', style: TextStyle(fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(
              '${previewZoom.toStringAsFixed(1)}x',
              style: const TextStyle(
                color: Color(0xFF167A4A),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Slider(
          value: previewZoom.clamp(0.7, 3.0).toDouble(),
          min: 0.7,
          max: 3.0,
          divisions: 23,
          onChanged: onPreviewZoomChanged,
        ),
        const SizedBox(height: 2),
        _MetricRow(
          label: '圖片尺寸',
          value:
              '${(draft.width * draft.resolutionM).toStringAsFixed(1)} x '
              '${(draft.height * draft.resolutionM).toStringAsFixed(1)} m',
        ),
        const SizedBox(height: 4),
        _MetricRow(
          label: '可割草面積',
          value: '${draft.areaM2.toStringAsFixed(1)} m²',
        ),
        const SizedBox(height: 12),
        _SheetActions(onBack: onBack, onNext: onNext),
      ],
    );
  }
}

class _AlignStep extends StatelessWidget {
  const _AlignStep({
    required this.draft,
    required this.onOpenAlign,
    required this.onBack,
    required this.onNext,
  });

  final ImageMissionDraft draft;
  final VoidCallback onOpenAlign;
  final VoidCallback onBack;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final aligned = draft.placement != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF4F7F5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFD8E3DC)),
          ),
          child: Row(
            children: [
              const Icon(Icons.map_outlined, color: Color(0xFF167A4A)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  aligned
                      ? '已對齊：在地圖上拖動圖層到 freespace 上。可再次調整。'
                      : '在地圖上把圖層拖動、縮放、旋轉，對齊到機器人採集的 freespace。',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: onOpenAlign,
          icon: const Icon(Icons.open_in_full),
          label: Text(aligned ? '重新在地圖上對齊' : '在地圖上對齊'),
        ),
        if (aligned) ...[
          const SizedBox(height: 6),
          Row(
            children: const [
              Icon(Icons.check_circle, color: Color(0xFF167A4A), size: 18),
              SizedBox(width: 6),
              Text(
                '已完成對齊',
                style: TextStyle(
                  color: Color(0xFF167A4A),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        _SheetActions(onBack: onBack, onNext: onNext),
      ],
    );
  }
}

class _RiskAndSubmitStep extends StatelessWidget {
  const _RiskAndSubmitStep({
    required this.draft,
    required this.previewZoom,
    required this.rosConnected,
    required this.onRiskPoint,
    required this.onClearRisk,
    required this.onBack,
    required this.onSubmit,
    required this.onExecute,
  });

  final ImageMissionDraft draft;
  final double previewZoom;
  final bool rosConnected;
  final ValueChanged<MapPoint> onRiskPoint;
  final VoidCallback onClearRisk;
  final VoidCallback onBack;
  final Future<bool> Function() onSubmit;
  final VoidCallback? onExecute;

  @override
  Widget build(BuildContext context) {
    final message = draft.submitMessage;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MaskPreview(
          draft: draft,
          height: 250,
          previewScale: previewZoom,
          startPoint: draft.startPose?.point,
          onTapImagePoint: onRiskPoint,
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _MetricRow(
                label: 'Area',
                value: '${draft.areaM2.toStringAsFixed(1)} m²',
              ),
            ),
            TextButton.icon(
              onPressed: draft.hasRiskMask ? onClearRisk : null,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('清除禁區'),
            ),
          ],
        ),
        if (message != null) ...[
          const SizedBox(height: 8),
          Text(
            message,
            style: TextStyle(
              color: draft.submitted
                  ? const Color(0xFF167A4A)
                  : const Color(0xFFB45309),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back),
              label: const Text('上一步'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: draft.canSubmit && !draft.submitting
                    ? () => unawaitedSubmit(context)
                    : null,
                icon: draft.submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.route_outlined),
                label: Text(rosConnected ? '送出生成路徑' : 'Mock 送出'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: onExecute,
          icon: const Icon(Icons.play_arrow),
          label: const Text('確認後執行'),
        ),
      ],
    );
  }

  void unawaitedSubmit(BuildContext context) {
    onSubmit().then((success) {
      if (!context.mounted) {
        return;
      }
      if (!success) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('圖片任務送出失敗')));
      }
    });
  }
}

class _SheetActions extends StatelessWidget {
  const _SheetActions({required this.onBack, required this.onNext});

  final VoidCallback onBack;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: onBack,
          icon: const Icon(Icons.arrow_back),
          label: const Text('上一步'),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('下一步'),
          ),
        ),
      ],
    );
  }
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF607D8B),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          value,
          style: const TextStyle(
            color: Color(0xFF17211C),
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }
}

class _MaskPreview extends StatelessWidget {
  const _MaskPreview({
    required this.draft,
    required this.height,
    this.previewScale = 1.0,
    this.startPoint,
    this.onTapImagePoint,
  });

  final ImageMissionDraft draft;
  final double height;
  final double previewScale;
  final MapPoint? startPoint;
  final ValueChanged<MapPoint>? onTapImagePoint;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return GestureDetector(
            onTapDown: onTapImagePoint == null
                ? null
                : (details) {
                    final point = _imagePointFromLocal(
                      details.localPosition,
                      size,
                      draft.width,
                      draft.height,
                      previewScale,
                    );
                    if (point != null) {
                      onTapImagePoint!(point);
                    }
                  },
            child: ClipRect(
              child: CustomPaint(
                painter: _MaskPreviewPainter(
                  draft: draft,
                  previewScale: previewScale,
                  startPoint: startPoint,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          );
        },
      ),
    );
  }

  static MapPoint? _imagePointFromLocal(
    Offset local,
    Size size,
    int imageWidth,
    int imageHeight,
    double previewScale,
  ) {
    final rect = _imageRect(size, imageWidth, imageHeight, previewScale);
    if (!rect.contains(local)) {
      return null;
    }
    final x = ((local.dx - rect.left) / rect.width * imageWidth)
        .clamp(0.0, imageWidth - 1.0)
        .toDouble();
    final y = ((local.dy - rect.top) / rect.height * imageHeight)
        .clamp(0.0, imageHeight - 1.0)
        .toDouble();
    return MapPoint(x, y);
  }
}

class _MaskPreviewPainter extends CustomPainter {
  const _MaskPreviewPainter({
    required this.draft,
    required this.previewScale,
    required this.startPoint,
  });

  final ImageMissionDraft draft;
  final double previewScale;
  final MapPoint? startPoint;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _imageRect(size, draft.width, draft.height, previewScale);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xFF111827),
    );
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, const Radius.circular(8)));

    final cellW = rect.width / draft.width;
    final cellH = rect.height / draft.height;
    final freePaint = Paint()..color = Colors.white;
    final riskPaint = Paint()
      ..color = const Color(0xFFE53935).withValues(alpha: 0.82);
    final riskMask = draft.riskMask;

    for (var y = 0; y < draft.height; y += 1) {
      final row = y * draft.width;
      for (var x = 0; x < draft.width; x += 1) {
        final idx = row + x;
        final pixelRect = Rect.fromLTWH(
          rect.left + x * cellW,
          rect.top + y * cellH,
          math.max(cellW, 0.7),
          math.max(cellH, 0.7),
        );
        if (draft.freeMask[idx] == 255) {
          canvas.drawRect(pixelRect, freePaint);
        }
        if (riskMask != null && riskMask[idx] == 255) {
          canvas.drawRect(pixelRect, riskPaint);
        }
      }
    }

    final start = startPoint;
    if (start != null) {
      final startOffset = _project(start, rect, draft.width, draft.height);
      _drawMarker(canvas, startOffset, 'S', const Color(0xFF1565C0));
    }

    canvas.restore();
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()
        ..color = const Color(0xFF263238)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _MaskPreviewPainter oldDelegate) {
    return oldDelegate.draft != draft ||
        oldDelegate.previewScale != previewScale ||
        oldDelegate.startPoint != startPoint;
  }

  static void _drawMarker(
    Canvas canvas,
    Offset center,
    String label,
    Color color,
  ) {
    canvas.drawCircle(center, 13, Paint()..color = Colors.white);
    canvas.drawCircle(center, 11, Paint()..color = color);
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w900,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center.translate(-painter.width / 2, -painter.height / 2),
    );
  }

  static Offset _project(
    MapPoint point,
    Rect rect,
    int imageWidth,
    int imageHeight,
  ) {
    return Offset(
      rect.left + point.x / imageWidth * rect.width,
      rect.top + point.y / imageHeight * rect.height,
    );
  }
}

Rect _imageRect(
  Size size,
  int imageWidth,
  int imageHeight,
  double previewScale,
) {
  final imageAspect = imageWidth / imageHeight;
  final boxAspect = size.width / size.height;
  final Rect fitRect;
  if (boxAspect > imageAspect) {
    final width = size.height * imageAspect;
    fitRect = Rect.fromLTWH((size.width - width) / 2, 0, width, size.height);
  } else {
    final height = size.width / imageAspect;
    fitRect = Rect.fromLTWH(0, (size.height - height) / 2, size.width, height);
  }
  final scale = previewScale.clamp(0.7, 3.0).toDouble();
  final scaledSize = Size(fitRect.width * scale, fitRect.height * scale);
  return Rect.fromCenter(
    center: fitRect.center,
    width: scaledSize.width,
    height: scaledSize.height,
  );
}
