import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mower_stdio/models/image_mission_draft.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/services/image_mission_processor.dart';

void main() {
  test('thresholdMask turns white pixels into free cells', () {
    final grayscale = Uint8List.fromList([0, 127, 128, 255]);
    final mask = ImageMissionProcessor.thresholdMask(grayscale, 127);
    expect(mask, [0, 0, 255, 255]);
  });

  test('otsuThreshold separates a bimodal image', () {
    final grayscale = Uint8List.fromList([
      ...List<int>.filled(20, 12),
      ...List<int>.filled(20, 220),
    ]);
    final threshold = ImageMissionProcessor.otsuThreshold(grayscale);
    final mask = ImageMissionProcessor.thresholdMask(grayscale, threshold);
    expect(mask.take(20), everyElement(0));
    expect(mask.skip(20), everyElement(255));
  });

  test('encodeMaskBase64 roundtrips row-major mask data', () {
    final mask = Uint8List.fromList([255, 0, 0, 255]);
    final encoded = ImageMissionProcessor.encodeMaskBase64(mask);
    expect(base64Decode(encoded), mask);
  });

  test('manual resolution scale computes area', () {
    final draft = ImageMissionDraft(
      sourceName: 'test.png',
      width: 2,
      height: 2,
      grayscale: Uint8List(4),
      freeMask: Uint8List.fromList([255, 0, 255, 0]),
      threshold: 128,
      resolutionM: 0.1,
    );

    expect(draft.resolutionM, closeTo(0.1, 0.0001));
    expect(draft.areaM2, closeTo(0.02, 0.0001));
  });

  test('imagePointToLocalMeters flips image y into local map y', () {
    final point = ImageMissionProcessor.imagePointToLocalMeters(
      const MapPoint(4, 2),
      imageHeight: 10,
      resolutionM: 0.05,
    );

    expect(point.x, closeTo(0.2, 0.0001));
    expect(point.y, closeTo(0.4, 0.0001));
  });
}
