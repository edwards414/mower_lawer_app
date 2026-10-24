import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:mower_stdio/models/base_station.dart';

Map<String, dynamic> _relpos({
  double n = 12.0,
  double e = -4.0,
  bool valid = true,
  String carrier = 'fixed',
  double acc = 0.012,
  int station = 0,
  bool refPosMiss = false,
  bool isMoving = false,
}) => {
  'age_s': 0.1,
  'itow_ms': 345600000,
  'ref_station_id': station,
  'valid': valid,
  'carrier_solution': carrier,
  'n_m': n,
  'e_m': e,
  'd_m': 0.1,
  'acc_n_m': acc,
  'acc_e_m': acc,
  'is_moving': isMoving,
  'ref_pos_miss': refPosMiss,
  'ref_obs_miss': false,
};

const _lat = 25.033;
const _lon = 121.5654;
const _distance = Distance();

bool _add(
  BaseStationEstimator est,
  Map<String, dynamic>? relpos, {
  double lat = _lat,
  double lon = _lon,
  double sigma = 0.014,
}) => est.add(relpos: relpos, roverLat: lat, roverLon: lon, roverSigmaM: sigma);

void main() {
  test('offsetLatLng moves by the given metres on the ellipsoid', () {
    final p = BaseStationEstimator.offsetLatLng(
      _lat,
      _lon,
      north: 30,
      east: -40,
    );
    // Vincenty on WGS84: a 3-4-5 triangle, 50 m
    expect(
      _distance.as(LengthUnit.Millimeter, const LatLng(_lat, _lon), p),
      closeTo(50000, 2),
    );
    final north = BaseStationEstimator.offsetLatLng(
      _lat,
      _lon,
      north: 30,
      east: 0,
    );
    expect(
      _distance.as(LengthUnit.Millimeter, const LatLng(_lat, _lon), north),
      closeTo(30000, 1),
    );
  });

  test('the base is the rover minus the relpos vector', () {
    final est = BaseStationEstimator();
    for (var i = 0; i < BaseStationEstimator.minSamples - 1; i++) {
      expect(_add(est, _relpos()), isTrue);
      expect(est.position, isNull, reason: 'not enough samples yet');
    }
    expect(_add(est, _relpos()), isTrue);
    final base = est.position!;
    expect(base.latitude, lessThan(_lat), reason: 'the rover is north of it');
    expect(base.longitude, greaterThan(_lon), reason: 'and west of it');
    expect(
      _distance.as(LengthUnit.Millimeter, const LatLng(_lat, _lon), base),
      closeTo(12649, 2), // sqrt(12² + 4²) m
    );
    expect(est.refStationId, 0);
  });

  test('only centimetre-grade samples of a fixed, local base are kept', () {
    final est = BaseStationEstimator();
    expect(_add(est, null), isFalse);
    expect(_add(est, _relpos(valid: false)), isFalse);
    expect(_add(est, _relpos(carrier: 'float')), isFalse);
    expect(_add(est, _relpos(acc: 0.2)), isFalse);
    expect(_add(est, _relpos(refPosMiss: true)), isFalse);
    expect(_add(est, _relpos(isMoving: true)), isFalse);
    expect(_add(est, _relpos(n: 3000, e: 0)), isFalse, reason: 'NTRIP caster');
    expect(_add(est, _relpos(), sigma: 0.5), isFalse, reason: 'no RTK on /fix');
    expect(_add(est, {..._relpos(), 'n_m': null}), isFalse);
    expect(est.sampleCount, 0);
  });

  test('the median ignores a stray sample', () {
    final est = BaseStationEstimator();
    for (var i = 0; i < 4; i++) {
      _add(est, _relpos());
    }
    final steady = est.position!;
    // a fix from the neighbouring epoch, 2 m off
    _add(est, _relpos(n: 14.0));
    expect(
      _distance.as(LengthUnit.Millimeter, steady, est.position!),
      lessThan(1),
    );
  });

  test('another base station starts over', () {
    final est = BaseStationEstimator();
    for (var i = 0; i < 5; i++) {
      _add(est, _relpos());
    }
    expect(_add(est, _relpos(station: 7)), isTrue);
    expect(est.sampleCount, 1);
    expect(est.refStationId, 7);
    expect(est.position, isNull);
  });

  test('the window keeps the newest samples', () {
    final est = BaseStationEstimator();
    for (var i = 0; i < BaseStationEstimator.window + 10; i++) {
      _add(est, _relpos());
    }
    expect(est.sampleCount, BaseStationEstimator.window);
  });
}
