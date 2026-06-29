import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';

class ImageMissionProcessingException implements Exception {
  const ImageMissionProcessingException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ImageMissionProcessor {
  const ImageMissionProcessor();

  static const int maxImageSidePx = 512;

  ImageMissionDraft decodeDraft(Uint8List bytes, {required String sourceName}) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      throw const ImageMissionProcessingException('圖片解碼失敗');
    }

    final maxSide = math.max(decoded.width, decoded.height);
    final source = maxSide <= maxImageSidePx
        ? decoded
        : img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxImageSidePx : null,
            height: decoded.height > decoded.width ? maxImageSidePx : null,
            interpolation: img.Interpolation.average,
          );

    final grayscale = grayscaleFromImage(source);
    final threshold = otsuThreshold(grayscale);
    return ImageMissionDraft(
      sourceName: sourceName,
      width: source.width,
      height: source.height,
      grayscale: grayscale,
      freeMask: thresholdMask(grayscale, threshold),
      threshold: threshold,
    );
  }

  static Uint8List grayscaleFromImage(img.Image source) {
    final out = Uint8List(source.width * source.height);
    var i = 0;
    for (var y = 0; y < source.height; y += 1) {
      for (var x = 0; x < source.width; x += 1) {
        final pixel = source.getPixel(x, y);
        out[i] = (0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b)
            .round()
            .clamp(0, 255)
            .toInt();
        i += 1;
      }
    }
    return out;
  }

  static int otsuThreshold(Uint8List grayscale) {
    if (grayscale.isEmpty) {
      return 128;
    }

    final histogram = List<int>.filled(256, 0);
    for (final value in grayscale) {
      histogram[value] += 1;
    }

    final total = grayscale.length;
    var totalWeightedSum = 0.0;
    for (var i = 0; i < histogram.length; i += 1) {
      totalWeightedSum += i * histogram[i];
    }

    var backgroundWeight = 0;
    var backgroundSum = 0.0;
    var bestVariance = -1.0;
    var bestThreshold = 128;

    for (var threshold = 0; threshold < 256; threshold += 1) {
      backgroundWeight += histogram[threshold];
      if (backgroundWeight == 0) {
        continue;
      }

      final foregroundWeight = total - backgroundWeight;
      if (foregroundWeight == 0) {
        break;
      }

      backgroundSum += threshold * histogram[threshold];
      final backgroundMean = backgroundSum / backgroundWeight;
      final foregroundMean =
          (totalWeightedSum - backgroundSum) / foregroundWeight;
      final meanDelta = backgroundMean - foregroundMean;
      final betweenClassVariance =
          backgroundWeight * foregroundWeight * meanDelta * meanDelta;

      if (betweenClassVariance > bestVariance) {
        bestVariance = betweenClassVariance;
        bestThreshold = threshold;
      }
    }

    return bestThreshold.clamp(0, 255);
  }

  static Uint8List thresholdMask(Uint8List grayscale, int threshold) {
    final clamped = threshold.clamp(0, 255);
    final out = Uint8List(grayscale.length);
    for (var i = 0; i < grayscale.length; i += 1) {
      out[i] = grayscale[i] > clamped ? 255 : 0;
    }
    return out;
  }

  static Uint8List emptyMask(int width, int height) {
    return Uint8List(width * height);
  }

  static String encodeMaskBase64(Uint8List mask) => base64Encode(mask);

  static MapPoint imagePointToLocalMeters(
    MapPoint imagePoint, {
    required int imageHeight,
    required double resolutionM,
  }) {
    return MapPoint(
      imagePoint.x * resolutionM,
      (imageHeight - imagePoint.y) * resolutionM,
    );
  }
}
