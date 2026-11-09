import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/geo_anchor.dart';

/// How far Google's satellite photo must move, on the ground, to sit where
/// things really are. Satellite photos are typically placed a metre or few
/// off; the NLSC aerial survey and the robot's RTK are the truth.
@immutable
class ImageryOffset {
  const ImageryOffset(this.eastM, this.northM);

  static const zero = ImageryOffset(0, 0);

  /// The step the alignment arrows move by.
  static const double stepM = 0.1;

  final double eastM;
  final double northM;

  bool get isZero => eastM == 0 && northM == 0;

  /// Moved by ([eastM], [northM]), kept on the 0.1 m grid (no float creep
  /// from many small steps).
  ImageryOffset moved(double eastM, double northM) =>
      ImageryOffset(_grid(this.eastM + eastM), _grid(this.northM + northM));

  static double _grid(double v) {
    final r = (v / stepM).round() * stepM;
    // 1 decimal; no -0.0.
    final d = double.parse(r.toStringAsFixed(1));
    return d == 0 ? 0 : d;
  }

  @override
  bool operator ==(Object other) =>
      other is ImageryOffset && other.eastM == eastM && other.northM == northM;

  @override
  int get hashCode => Object.hash(eastM, northM);

  @override
  String toString() => 'ImageryOffset(E $eastM m, N $northM m)';
}

/// The alignment of Google's photo, one per site, kept on this phone.
/// Listeners hear of every save, so a map already on screen moves at once.
class ImageryOffsetStore extends ChangeNotifier {
  static final ImageryOffsetStore shared = ImageryOffsetStore();

  /// A site is its map origin to ~100 m: the datum is re-sent often, and a
  /// re-survey of the same lawn should keep its alignment.
  @visibleForTesting
  static String keyFor(GeoAnchor site) =>
      'google_imagery_offset_'
      '${site.originLat.toStringAsFixed(3)}_${site.originLon.toStringAsFixed(3)}';

  Future<ImageryOffset> load(GeoAnchor site) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(keyFor(site));
    final parts = raw?.split(',');
    if (parts == null || parts.length != 2) return ImageryOffset.zero;
    final east = double.tryParse(parts[0]);
    final north = double.tryParse(parts[1]);
    if (east == null || north == null || !east.isFinite || !north.isFinite) {
      return ImageryOffset.zero;
    }
    return ImageryOffset(east, north);
  }

  Future<void> save(GeoAnchor site, ImageryOffset offset) async {
    final prefs = await SharedPreferences.getInstance();
    if (offset.isZero) {
      await prefs.remove(keyFor(site));
    } else {
      await prefs.setString(keyFor(site), '${offset.eastM},${offset.northM}');
    }
    notifyListeners();
  }
}
