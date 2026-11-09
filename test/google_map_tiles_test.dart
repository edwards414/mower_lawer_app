import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/google_map_tiles.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';

final _site = LatLngBounds(
  const LatLng(23.6935, 120.5372),
  const LatLng(23.6945, 120.5382),
);

/// Google's two endpoints, answering as told and counting the calls.
class _FakeGoogle {
  int sessions = 0;
  int viewports = 0;
  int sessionStatus = 200;

  /// Sessions Google no longer takes.
  final Set<String> refused = {};
  final List<Map<String, String>> headersSeen = [];

  late final client = MockClient((request) async {
    headersSeen.add(request.headers);
    if (request.url.path == '/v1/createSession') {
      sessions++;
      if (sessionStatus != 200) {
        return http.Response(
          jsonEncode({
            'error': {'message': 'API key not valid'},
          }),
          sessionStatus,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect(body['mapType'], 'satellite');
      return http.Response(
        jsonEncode({
          'session': 'S$sessions',
          // Two weeks out.
          'expiry':
              '${DateTime.now().add(const Duration(days: 14)).millisecondsSinceEpoch ~/ 1000}',
          'tileWidth': 256,
          'imageFormat': 'jpeg',
        }),
        200,
      );
    }
    if (request.url.path == '/tile/v1/viewport') {
      viewports++;
      if (refused.contains(request.url.queryParameters['session'])) {
        return http.Response('{"error":{"message":"session expired"}}', 400);
      }
      return http.Response(
        jsonEncode({
          'copyright': 'Imagery ©2025 Airbus, Map data ©2025 Google',
          'maxZoomRects': [
            {
              'maxZoom': 19,
              'north': 90,
              'south': -90,
              'east': 180,
              'west': -180,
            },
            {'maxZoom': 21, 'north': 24, 'south': 23, 'east': 121, 'west': 120},
            // Deeper, but somewhere else.
            {'maxZoom': 22, 'north': 26, 'south': 25, 'east': 122, 'west': 121},
          ],
        }),
        200,
      );
    }
    return http.Response('', 404);
  });

  GoogleMapTiles tiles({String key = 'AIzaTESTKEY123'}) => GoogleMapTiles(
    apiKey: key,
    client: client,
    appHeaders: () async => {'X-Ios-Bundle-Identifier': 'com.edwards.mower'},
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no key: nothing is asked of Google', () async {
    final google = _FakeGoogle();
    final tiles = google.tiles(key: '');
    expect(tiles.configured, isFalse);
    expect(await tiles.sourceFor(_site), isNull);
    expect(google.headersSeen, isEmpty);
  });

  test('a session gives the tiles, the copyright and the site depth', () async {
    final google = _FakeGoogle();
    final source = await google.tiles().sourceFor(_site);
    expect(source, isNotNull);
    expect(
      source!.urlTemplate,
      'https://tile.googleapis.com/v1/2dtiles/{z}/{x}/{y}'
      '?session=S1&key=AIzaTESTKEY123',
    );
    expect(source.copyright, 'Imagery ©2025 Airbus, Map data ©2025 Google');
    // The deepest rectangle that holds the site, not the deepest anywhere.
    expect(source.maxNativeZoom, 21);
    // The app names itself on every call, tiles included.
    expect(source.headers['X-Ios-Bundle-Identifier'], 'com.edwards.mower');
    expect(
      google.headersSeen.every(
        (h) => h['X-Ios-Bundle-Identifier'] == 'com.edwards.mower',
      ),
      isTrue,
    );
  });

  test('the session is kept for its two weeks, not opened per map', () async {
    final google = _FakeGoogle();
    await google.tiles().sourceFor(_site);
    await google.tiles().sourceFor(_site);
    expect(google.sessions, 1);
    expect(google.viewports, 2);

    // Another key never reuses it.
    await google.tiles(key: 'AIzaOTHERKEY999').sourceFor(_site);
    expect(google.sessions, 2);
  });

  test('a session Google stopped taking is replaced, once', () async {
    final google = _FakeGoogle();
    await google.tiles().sourceFor(_site);
    google.refused.add('S1');
    final source = await google.tiles().sourceFor(_site);
    expect(source!.urlTemplate, contains('session=S2'));
    expect(google.sessions, 2);
  });

  test('a refused key leaves the map on NLSC', () async {
    final google = _FakeGoogle()..sessionStatus = 403;
    expect(await google.tiles().sourceFor(_site), isNull);
    expect(google.viewports, 0);
  });

  test('depth falls back to Google usual when no rectangle says', () {
    expect(GoogleMapTiles.maxZoomAt(null, const LatLng(23.69, 120.53)), 20);
    expect(GoogleMapTiles.maxZoomAt(const [], const LatLng(23.69, 120.53)), 20);
  });

  testWidgets('with Google tiles the map shows its logo and copyright', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final ros = _QuietRosbridge();
    final mission = MissionMockProvider(rosbridge: ros);
    await tester.pump();
    final google = _FakeGoogle();

    await tester.pumpWidget(
      MaterialApp(
        home: SatelliteMapView(
          mission: mission,
          anchor: const GeoAnchor(
            originLat: 23.6939508,
            originLon: 120.5376539,
          ),
          aiEnhance: true,
          googleTiles: google.tiles(),
        ),
      ),
    );
    // NLSC until the session is open.
    expect(
      tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate,
      SatelliteMapView.nlscTileUrl,
    );
    expect(_googleLogo(), findsNothing);

    for (var i = 0; i < 5; i++) {
      await tester.pump();
    }
    expect(_googleLogo(), findsOneWidget);
    // Read out as "Google Maps", as Google asks.
    expect(
      find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == 'Google Maps',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Imagery ©2025 Airbus, Map data ©2025 Google'),
      findsOneWidget,
    );
    // As small and out of the way as Google allows: the 16 dp minimum, in
    // the bottom-left corner, the copyright in a narrow block over it.
    final logo = tester.getRect(_googleLogo());
    expect(logo.height, 16);
    expect(logo.left, 10);
    final copyright = tester.getRect(
      find.text('Imagery ©2025 Airbus, Map data ©2025 Google'),
    );
    expect(copyright.bottom, lessThanOrEqualTo(logo.top));
    expect(copyright.left, logo.left);
    expect(copyright.width, lessThanOrEqualTo(160));
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(layer.urlTemplate, contains('tile.googleapis.com'));
    expect(layer.maxNativeZoom, 21);
    // The AI tiles sharpen NLSC's photo only: none over Google's.
    expect(find.textContaining('AI 強化'), findsNothing);
    expect(find.byType(OverlayImageLayer), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('with no key the map stays on NLSC', (tester) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final ros = _QuietRosbridge();
    final mission = MissionMockProvider(rosbridge: ros);
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: SatelliteMapView(
          mission: mission,
          anchor: const GeoAnchor(
            originLat: 23.6939508,
            originLon: 120.5376539,
          ),
          googleTiles: _FakeGoogle().tiles(key: ''),
        ),
      ),
    );
    await tester.pump();
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    expect(layer.urlTemplate, SatelliteMapView.nlscTileUrl);
    expect(_googleLogo(), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

Finder _googleLogo() => find.byWidgetPredicate(
  (w) =>
      w is Image &&
      w.image is AssetImage &&
      (w.image as AssetImage).assetName == 'assets/images/google_maps_logo.png',
);

class _QuietRosbridge extends RosbridgeService {
  _QuietRosbridge() : super(url: 'ws://robot.test:9090');

  @override
  Stream<RosbridgeTopicMessage> get messages => const Stream.empty();

  @override
  Stream<RosbridgeConnectionState> get states => const Stream.empty();

  @override
  Future<void> loadSavedRobotIp() async {}

  @override
  void connect() {}

  @override
  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {}
}
