import 'dart:typed_data';

import 'mission_mock.dart';

class ImageMissionStartPose {
  const ImageMissionStartPose({required this.point, required this.headingRad});

  final MapPoint point;
  final double headingRad;
}

/// Placement of the uploaded image mask onto the real map, captured by the
/// user dragging/rotating/scaling the overlay over the collected freespace.
///
/// - [mapAnchor]   world (map-frame, metres) location where the start pixel sits.
/// - [mapRotationRad] image rotation in the map frame (theta).
/// - [mapScale]    uniform scale multiplier applied on top of [ImageMissionDraft.resolutionM].
class ImageMissionPlacement {
  const ImageMissionPlacement({
    required this.mapAnchor,
    this.mapRotationRad = 0.0,
    this.mapScale = 1.0,
  });

  final MapPoint mapAnchor;
  final double mapRotationRad;
  final double mapScale;

  ImageMissionPlacement copyWith({
    MapPoint? mapAnchor,
    double? mapRotationRad,
    double? mapScale,
  }) {
    return ImageMissionPlacement(
      mapAnchor: mapAnchor ?? this.mapAnchor,
      mapRotationRad: mapRotationRad ?? this.mapRotationRad,
      mapScale: mapScale ?? this.mapScale,
    );
  }
}

class ImageMissionDraft {
  const ImageMissionDraft({
    required this.sourceName,
    required this.width,
    required this.height,
    required this.grayscale,
    required this.freeMask,
    this.riskMask,
    required this.threshold,
    this.resolutionM = defaultResolutionM,
    this.startPose,
    this.placement,
    this.zoneId = 9001,
    this.submitting = false,
    this.submitted = false,
    this.submitMessage,
    this.submittedAreaM2,
  });

  static const defaultZoneId = 9001;
  static const defaultResolutionM = 0.05;

  final String sourceName;
  final int width;
  final int height;
  final Uint8List grayscale;
  final Uint8List freeMask;
  final Uint8List? riskMask;
  final int threshold;
  final double resolutionM;
  final ImageMissionStartPose? startPose;
  final ImageMissionPlacement? placement;
  final int zoneId;
  final bool submitting;
  final bool submitted;
  final String? submitMessage;
  final double? submittedAreaM2;

  int get freeCellCount {
    var count = 0;
    for (final value in freeMask) {
      if (value == 255) {
        count += 1;
      }
    }
    return count;
  }

  double get areaM2 => freeCellCount * resolutionM * resolutionM;

  bool get hasRiskMask => riskMask?.any((value) => value == 255) ?? false;

  bool get canSubmit =>
      !submitting &&
      grayscale.length == width * height &&
      freeMask.length == width * height &&
      (riskMask == null || riskMask!.length == width * height) &&
      resolutionM > 0 &&
      startPose != null &&
      placement != null &&
      freeCellCount > 0;

  ImageMissionDraft copyWith({
    String? sourceName,
    int? width,
    int? height,
    Uint8List? grayscale,
    Uint8List? freeMask,
    Uint8List? riskMask,
    bool clearRiskMask = false,
    int? threshold,
    double? resolutionM,
    ImageMissionStartPose? startPose,
    bool clearStartPose = false,
    ImageMissionPlacement? placement,
    bool clearPlacement = false,
    int? zoneId,
    bool? submitting,
    bool? submitted,
    String? submitMessage,
    bool clearSubmitMessage = false,
    double? submittedAreaM2,
    bool clearSubmittedArea = false,
  }) {
    return ImageMissionDraft(
      sourceName: sourceName ?? this.sourceName,
      width: width ?? this.width,
      height: height ?? this.height,
      grayscale: grayscale ?? this.grayscale,
      freeMask: freeMask ?? this.freeMask,
      riskMask: clearRiskMask ? null : riskMask ?? this.riskMask,
      threshold: threshold ?? this.threshold,
      resolutionM: resolutionM ?? this.resolutionM,
      startPose: clearStartPose ? null : startPose ?? this.startPose,
      placement: clearPlacement ? null : placement ?? this.placement,
      zoneId: zoneId ?? this.zoneId,
      submitting: submitting ?? this.submitting,
      submitted: submitted ?? this.submitted,
      submitMessage: clearSubmitMessage
          ? null
          : submitMessage ?? this.submitMessage,
      submittedAreaM2: clearSubmittedArea
          ? null
          : submittedAreaM2 ?? this.submittedAreaM2,
    );
  }
}
