import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Geo-reference for the local ROS `map` frame: where map-frame (0,0) sits on
/// Earth and how the map's +X axis is oriented relative to true north. With
/// this anchor, any map-frame point (metres) can be placed on a satellite map.
///
/// Source-agnostic: the anchor can come from the backend (navsat_transform
/// datum) OR from a one-time manual calibration on the satellite image.
class GeoAnchor {
  const GeoAnchor({
    required this.originLat,
    required this.originLon,
    this.bearingRad = 0.0,
  });

  /// Latitude/longitude of map-frame point (0, 0).
  final double originLat;
  final double originLon;

  /// Bearing of the map frame's +X axis, clockwise from true north (radians).
  /// 0 means map +X points North. (map +Y is 90° counter-clockwise from +X,
  /// per ROS REP-103.)
  final double bearingRad;

  static const double _metersPerDegLat = 111320.0;

  /// Convert a map-frame point in metres to geographic lat/lon using a local
  /// equirectangular (flat-Earth) approximation — sub-metre accurate over a
  /// lawn-sized area, which is all this overlay needs.
  LatLng worldToLatLng(double x, double y) {
    final b = bearingRad;
    final sinB = math.sin(b);
    final cosB = math.cos(b);
    // Displacement of (x, y) in local East/North metres.
    final east = x * sinB - y * cosB;
    final north = x * cosB + y * sinB;
    final metersPerDegLon =
        _metersPerDegLat * math.cos(originLat * math.pi / 180.0);
    final lat = originLat + north / _metersPerDegLat;
    final lon = originLon +
        (metersPerDegLon.abs() < 1e-9 ? 0.0 : east / metersPerDegLon);
    return LatLng(lat, lon);
  }

  GeoAnchor copyWith({double? originLat, double? originLon, double? bearingRad}) {
    return GeoAnchor(
      originLat: originLat ?? this.originLat,
      originLon: originLon ?? this.originLon,
      bearingRad: bearingRad ?? this.bearingRad,
    );
  }

  Map<String, dynamic> toJson() => {
        'origin_lat': originLat,
        'origin_lon': originLon,
        'bearing_rad': bearingRad,
      };

  static GeoAnchor? fromJson(Map<String, dynamic> json) {
    final lat = (json['origin_lat'] as num?)?.toDouble();
    final lon = (json['origin_lon'] as num?)?.toDouble();
    if (lat == null || lon == null) {
      return null;
    }
    return GeoAnchor(
      originLat: lat,
      originLon: lon,
      bearingRad: (json['bearing_rad'] as num?)?.toDouble() ?? 0.0,
    );
  }
}
