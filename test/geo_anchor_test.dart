import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/models/geo_anchor.dart';

void main() {
  test('latLngToWorld inverts worldToLatLng for any bearing', () {
    for (final bearing in [0.0, 0.7, math.pi / 2, -2.1, math.pi]) {
      final anchor = GeoAnchor(
        originLat: 24.7869,
        originLon: 120.9968,
        bearingRad: bearing,
      );
      for (final (x, y) in [(0.0, 0.0), (12.5, -3.0), (-40.0, 85.0)]) {
        final back = anchor.latLngToWorld(anchor.worldToLatLng(x, y));
        expect(back.x, closeTo(x, 1e-6), reason: 'bearing=$bearing');
        expect(back.y, closeTo(y, 1e-6), reason: 'bearing=$bearing');
      }
    }
  });

  test('bearing 0: map +X points north, +Y points west (REP-103)', () {
    const anchor = GeoAnchor(originLat: 24.7869, originLon: 120.9968);
    expect(anchor.worldToLatLng(10, 0).latitude, greaterThan(anchor.originLat));
    expect(anchor.worldToLatLng(0, 10).longitude, lessThan(anchor.originLon));
  });
}
