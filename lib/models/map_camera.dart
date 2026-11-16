import 'dart:math' as math;

import 'mission_mock.dart';

/// Where the map page is looking: one camera shared by the schematic map and
/// the satellite map, so switching between them (or into drawing, which uses
/// the schematic one) keeps the same place at the same size.
///
/// A plain holder the two map widgets read when they appear and write as the
/// view changes; neither rebuilds because the other wrote.
class MapViewCamera {
  /// Screen pixels per metre. Null until someone has chosen a zoom: the
  /// schematic map then fits its content.
  double? scale;

  /// The map-frame point at the centre of the screen.
  MapPoint? center;

  /// Closest and widest the schematic map zooms (px per metre).
  static const double minScale = 0.45;
  static const double maxScale = 160;

  /// Pixels per metre of a Web-Mercator map at [zoom] and [latitude].
  static double scaleOfZoom(double zoom, double latitude) =>
      math.pow(2, zoom) /
      (156543.03392 * math.cos(latitude * math.pi / 180));

  /// The Web-Mercator zoom that shows [scale] pixels per metre at [latitude].
  static double zoomOfScale(double scale, double latitude) =>
      math.log(scale * 156543.03392 * math.cos(latitude * math.pi / 180)) /
      math.ln2;
}
