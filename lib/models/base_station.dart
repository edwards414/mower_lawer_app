import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Where the RTK base station stands, worked out from the robot's own GNSS:
/// the rover's `/fix` minus the base → rover vector of NAV-RELPOSNED
/// (`relpos` in `/gps/status`, see mower_path_planning/docs/ROBOT_API.md).
/// In the current design the base antenna sits on the charging dock, so this
/// is also where the robot charges.
///
/// The base does not move, so the estimate is the per-axis median of the
/// recent samples, and a sample is kept only when both halves are
/// centimetre-grade. The two topics carry no common stamp, so a sample may
/// pair a relpos with the neighbouring epoch's fix; the median absorbs that
/// as well as a stray bad epoch.
class BaseStationEstimator {
  /// Samples the median is taken over (about half a minute at 1 Hz).
  static const int window = 30;

  /// Samples needed before a position is reported.
  static const int minSamples = 3;

  /// 1σ horizontal accuracy both the relpos and the fix need.
  static const double maxSigmaM = 0.10;

  /// A base further away than this is not a dock on this lawn (it would be
  /// an NTRIP caster's station); it is not reported.
  static const double maxBaselineM = 300;

  final List<LatLng> _samples = [];
  int? _refStationId;

  /// RTCM 1005 station id of the base the samples belong to.
  int? get refStationId => _refStationId;

  int get sampleCount => _samples.length;

  LatLng? get position {
    if (_samples.length < minSamples) return null;
    return LatLng(
      _median(_samples.map((p) => p.latitude)),
      _median(_samples.map((p) => p.longitude)),
    );
  }

  void clear() {
    _samples.clear();
    _refStationId = null;
  }

  /// Adds the `relpos` object of one `/gps/status` against the rover's fix
  /// of the same moment. Returns whether the sample was kept.
  bool add({
    required Object? relpos,
    required double roverLat,
    required double roverLon,
    required double roverSigmaM,
  }) {
    if (relpos is! Map) return false;
    final north = _num(relpos['n_m']);
    final east = _num(relpos['e_m']);
    final accN = _num(relpos['acc_n_m']);
    final accE = _num(relpos['acc_e_m']);
    final station = _num(relpos['ref_station_id'])?.toInt();
    if (relpos['valid'] != true ||
        relpos['carrier_solution'] != 'fixed' ||
        // extrapolated base data, or a moving base: not a dock
        relpos['ref_pos_miss'] == true ||
        relpos['ref_obs_miss'] == true ||
        relpos['is_moving'] == true ||
        north == null ||
        east == null ||
        accN == null ||
        accE == null ||
        math.sqrt(accN * accN + accE * accE) > maxSigmaM ||
        math.sqrt(north * north + east * east) > maxBaselineM ||
        !roverLat.isFinite ||
        !roverLon.isFinite ||
        !roverSigmaM.isFinite ||
        roverSigmaM > maxSigmaM) {
      return false;
    }
    if (station != _refStationId) {
      // another base: the old samples describe somewhere else
      _samples.clear();
      _refStationId = station;
    }
    _samples.add(offsetLatLng(roverLat, roverLon, north: -north, east: -east));
    if (_samples.length > window) _samples.removeAt(0);
    return true;
  }

  /// [lat]/[lon] moved by [north]/[east] metres on the WGS84 ellipsoid
  /// (local radii of curvature; exact enough for a few hundred metres).
  static LatLng offsetLatLng(
    double lat,
    double lon, {
    required double north,
    required double east,
  }) {
    const a = 6378137.0;
    const e2 = 6.69437999014e-3;
    final phi = lat * math.pi / 180;
    final s = math.sin(phi);
    final w = 1 - e2 * s * s;
    final meridional = a * (1 - e2) / (w * math.sqrt(w));
    final primeVertical = a / math.sqrt(w);
    return LatLng(
      lat + north / meridional * 180 / math.pi,
      lon + east / (primeVertical * math.cos(phi)) * 180 / math.pi,
    );
  }

  static double? _num(Object? v) =>
      v is num && v.isFinite ? v.toDouble() : null;

  static double _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    final mid = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
  }
}
