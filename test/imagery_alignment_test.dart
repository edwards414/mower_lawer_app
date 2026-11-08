import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/screens/imagery_alignment_screen.dart';
import 'package:mower_stdio/services/google_map_tiles.dart';
import 'package:mower_stdio/services/imagery_offset_store.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';

const _site = GeoAnchor(
  originLat: 23.6939508,
  originLon: 120.5376539,
  source: 'navsat',
);
const _otherSite = GeoAnchor(originLat: 25.03, originLon: 121.56);

/// Google answering with a session and the site's depth.
GoogleMapTiles _google() => GoogleMapTiles(
  apiKey: 'AIzaTEST',
  appHeaders: () async => const {},
  client: MockClient((request) async {
    if (request.url.path == '/v1/createSession') {
      return http.Response(
        jsonEncode({
          'session': 'S',
          'expiry':
              '${DateTime.now().add(const Duration(days: 14)).millisecondsSinceEpoch ~/ 1000}',
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({'copyright': 'Imagery ©2026 Maxar', 'maxZoomRects': []}),
      200,
    );
  }),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the arrows step 0.1 m without float creep', () {
    var o = ImageryOffset.zero;
    for (var i = 0; i < 7; i++) {
      o = o.moved(ImageryOffset.stepM, 0);
    }
    expect(o.eastM, 0.7);
    o = o.moved(-0.7, -0.3);
    expect(o, const ImageryOffset(0, -0.3));
    expect(o.eastM.isNegative, isFalse, reason: 'no -0.0');
  });

  test('the readout says which way, in metres', () {
    expect(describeOffset(ImageryOffset.zero), '不偏移');
    expect(describeOffset(const ImageryOffset(1.4, 0)), '往東 1.4 m');
    expect(
      describeOffset(const ImageryOffset(-1.4, 1.1)),
      '往西 1.4 m · 往北 1.1 m',
    );
    expect(describeOffset(const ImageryOffset(0, -0.2)), '往南 0.2 m');
  });

  test('each site keeps its own alignment; saving tells the maps', () async {
    final store = ImageryOffsetStore();
    var told = 0;
    store.addListener(() => told++);

    await store.save(_site, const ImageryOffset(-1.4, 1.1));
    expect(told, 1);
    expect(await store.load(_site), const ImageryOffset(-1.4, 1.1));
    expect(await store.load(_otherSite), ImageryOffset.zero);
    // The datum re-sent, a little different: still this site.
    expect(
      await store.load(
        const GeoAnchor(originLat: 23.69396, originLon: 120.53768),
      ),
      const ImageryOffset(-1.4, 1.1),
    );

    await store.save(_site, ImageryOffset.zero);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(ImageryOffsetStore.keyFor(_site)), isFalse);
  });

  test('a ground offset becomes the right screen shift', () {
    // ~0.273 m a pixel at z19 here; north is up the screen.
    final px = GroundShift.pixels(const ImageryOffset(1, 1), 23.69, 19);
    expect(px.dx, closeTo(3.66, 0.01));
    expect(px.dy, closeTo(-3.66, 0.01));
    // One zoom in, twice the pixels.
    expect(
      GroundShift.pixels(const ImageryOffset(1, 0), 23.69, 20).dx,
      closeTo(7.32, 0.02),
    );
  });

  testWidgets('the map moves Google photo by the saved alignment', (
    tester,
  ) async {
    final ros = _QuietRosbridge();
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = MissionMockProvider(rosbridge: ros);
    await tester.pump();
    final store = ImageryOffsetStore();
    await store.save(_site, const ImageryOffset(-1.4, 1.1));

    await tester.pumpWidget(
      MaterialApp(
        home: SatelliteMapView(
          mission: mission,
          anchor: _site,
          googleTiles: _google(),
          offsetStore: store,
        ),
      ),
    );
    await _settle(tester);
    GroundShift shift() => tester.widget<GroundShift>(find.byType(GroundShift));
    expect(shift().offset, const ImageryOffset(-1.4, 1.1));
    // Only Google's photo moves: NLSC's is the reference.
    expect(
      find.descendant(
        of: find.byType(GroundShift),
        matching: find.byType(TileLayer),
      ),
      findsOneWidget,
    );

    // Saved from the alignment page: the map on screen follows.
    await store.save(_site, const ImageryOffset(0.5, 0));
    await _settle(tester);
    expect(shift().offset, const ImageryOffset(0.5, 0));

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('the page nudges Google photo over NLSC and saves it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final ros = _QuietRosbridge();
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = MissionMockProvider(rosbridge: ros);
    await tester.pump();
    mission.mapGeoAnchor = _site;
    final store = ImageryOffsetStore();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ImageryAlignmentScreen(
                      mission: mission,
                      store: store,
                      googleTiles: _google(),
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);

    expect(find.text('不偏移'), findsOneWidget);
    // NLSC's photo is laid over Google's to align by.
    expect(
      find.descendant(
        of: find.byType(Opacity),
        matching: find.byType(TileLayer),
      ),
      findsOneWidget,
    );

    for (var i = 0; i < 3; i++) {
      await tester.tap(find.byTooltip('往西'));
    }
    await tester.tap(find.byTooltip('往北'));
    await tester.pump();
    expect(find.text('往西 0.3 m · 往北 0.1 m'), findsOneWidget);
    expect(
      tester.widget<GroundShift>(find.byType(GroundShift)).offset,
      const ImageryOffset(-0.3, 0.1),
    );
    // Nothing saved until 儲存.
    expect(await store.load(_site), ImageryOffset.zero);

    await tester.tap(find.text('儲存'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(await store.load(_site), const ImageryOffset(-0.3, 0.1));
    // Saved, the page closes.
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ImageryAlignmentScreen), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('with no GPS position for the map the page says so', (
    tester,
  ) async {
    final ros = _QuietRosbridge();
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = MissionMockProvider(rosbridge: ros);
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: ImageryAlignmentScreen(
          mission: mission,
          store: ImageryOffsetStore(),
          googleTiles: _google(),
        ),
      ),
    );
    expect(find.textContaining('地圖還沒有 GPS 位置'), findsOneWidget);
    expect(find.byType(SatelliteMapView), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

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
