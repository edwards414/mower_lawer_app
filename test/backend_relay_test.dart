import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/models/paired_robot.dart';
import 'package:mower_stdio/providers/robot_registry.dart';
import 'package:mower_stdio/services/backend_client.dart';
import 'package:mower_stdio/services/relay_framing.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';

const _secret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _backendQr =
    'https://mower.fxrbindi.com/pair?v=1&id=MW-7K3Q9P&s=$_secret&n=bench'
    '&h=wss://api.mower.fxrbindi.com/v1/relay/app&l=192.168.1.5';
const _legacyQr =
    'https://mower.fxrbindi.com/pair?v=1&id=MW-7K3Q9P&s=$_secret&h=wss://control.fxrbindi.com';

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test('backend relay URL gets the robot id, legacy relay stays as is', () {
    final r = PairedRobot.fromPairUrl(_backendQr);
    expect(r.usesBackendRelay, isTrue);
    expect(r.relayWsUrl, 'wss://api.mower.fxrbindi.com/v1/relay/app/MW-7K3Q9P');
    expect(r.backendBaseUrl, 'https://api.mower.fxrbindi.com');
    expect(r.preferredUrl, r.relayWsUrl);

    final legacy = PairedRobot.fromPairUrl(_legacyQr);
    expect(legacy.usesBackendRelay, isFalse);
    expect(legacy.relayWsUrl, 'wss://control.fxrbindi.com');
    expect(legacy.backendBaseUrl, '');

    final local = PairedRobot(id: 'MW-7K3Q9P', secret: _secret, relayUrl: 'ws://127.0.0.1:8787/v1/relay/app/');
    expect(local.relayWsUrl, 'ws://127.0.0.1:8787/v1/relay/app/MW-7K3Q9P');
    expect(local.backendBaseUrl, 'http://127.0.0.1:8787');
  });

  test('framed endpoint speaks mrelay1: subprotocol, chunked send, reassembled receive', () async {
    final channel = _FakeWebSocketChannel();
    final sent = <dynamic>[];
    final sub = channel.sent.stream.listen(sent.add);
    List<String> offered = const [];
    Map<String, dynamic> headersSeen = const {};
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) {
        offered = protocols;
        headersSeen = headers;
        return channel;
      },
    );
    service.configureEndpoint(
      url: 'wss://api.test/v1/relay/app/MW-7K3Q9P',
      authHeaders: () => {'X-Mower-Robot': 'MW-7K3Q9P'},
      framed: true,
    );
    expect(offered, ['mrelay1']);
    expect(headersSeen['X-Mower-Robot'], 'MW-7K3Q9P');
    expect(headersSeen.containsKey('CF-Access-Client-Id'), isFalse);
    channel.markReady();
    await _flush();

    service.subscribe('/odom');
    await _flush();
    expect(sent, hasLength(1));
    expect(sent.single, isA<Uint8List>());
    final frame = sent.single as Uint8List;
    expect(frame[0], RelayFraming.textFinal);
    expect(jsonDecode(utf8.decode(frame.sublist(1)))['topic'], '/odom');

    // a publish split over two frames arrives as one topic message
    final messages = <RosbridgeTopicMessage>[];
    final msgSub = service.messages.listen(messages.add);
    final json = jsonEncode({'op': 'publish', 'topic': '/robot/info', 'msg': {'data': 'x' * 3000}});
    final bytes = utf8.encode(json);
    channel.addIncoming(Uint8List.fromList([RelayFraming.textMore, ...bytes.sublist(0, 1000)]));
    channel.addIncoming(Uint8List.fromList([RelayFraming.textFinal, ...bytes.sublist(1000)]));
    await _flush();
    expect(messages, hasLength(1));
    expect(messages.single.topic, '/robot/info');

    // a plain text frame still works (LAN / legacy path shares the parser)
    channel.addIncoming(jsonEncode({'op': 'publish', 'topic': '/t', 'msg': {}}));
    await _flush();
    expect(messages, hasLength(2));

    service.dispose();
    await sub.cancel();
    await msgSub.cancel();
  });

  test('registry probes the LAN first, then falls back to the framed relay', () async {
    final configured = <({String url, bool framed})>[];
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (uri, {headers = const <String, dynamic>{}, protocols = const <String>[]}) {
        configured.add((url: uri.toString(), framed: protocols.contains('mrelay1')));
        return channel;
      },
    );
    var lanReachable = false;
    final probed = <String>[];
    final registry = RobotRegistry(
      rosbridge: service,
      store: MemoryPairingStore(),
      backend: BackendClient(client: MockClient((_) async => http.Response('{}', 404))),
      lanProbe: (url, headers) async {
        probed.add(url);
        expect(headers['X-Mower-Robot'], 'MW-7K3Q9P');
        return lanReachable;
      },
    );
    await registry.load();
    await registry.pairFromText(_backendQr);
    await _flush();
    expect(probed, ['ws://192.168.1.5:9090']);
    expect(registry.activeRoute, 'relay');
    expect(configured.last.url, 'wss://api.mower.fxrbindi.com/v1/relay/app/MW-7K3Q9P');
    expect(configured.last.framed, isTrue);

    lanReachable = true;
    await registry.select('MW-7K3Q9P'); // no-op: already active
    await registry.update('MW-7K3Q9P', name: 'renamed'); // re-routes the active robot
    await _flush();
    expect(registry.activeRoute, 'lan');
    expect(configured.last.url, 'ws://192.168.1.5:9090');
    expect(configured.last.framed, isFalse);

    // pinned to the LAN: no probe
    probed.clear();
    await registry.update('MW-7K3Q9P', preferLan: true);
    expect(probed, isEmpty);
    expect(registry.activeRoute, 'lan');
    service.dispose();
  });

  test('camera base URL follows the route: LAN MediaMTX, QR override, backend HTTP relay', () async {
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    var lanReachable = false;
    final registry = RobotRegistry(
      rosbridge: service,
      store: MemoryPairingStore(),
      backend: BackendClient(client: MockClient((_) async => http.Response('{}', 404))),
      lanProbe: (_, _) async => lanReachable,
    );
    await registry.load();
    await registry.pairFromText(_backendQr);
    await _flush();
    expect(registry.activeRoute, 'relay');
    expect(
      service.cameraBaseUrl,
      'https://api.mower.fxrbindi.com/v1/robots/MW-7K3Q9P/http',
      reason: 'phase 3: WHEP signaling relayed through the backend',
    );
    expect(service.cameraIceServersUrl, 'https://api.mower.fxrbindi.com/v1/robots/MW-7K3Q9P/turn');
    expect(service.cameraHeaders()['X-Mower-Robot'], 'MW-7K3Q9P');
    expect(service.cameraHeaders()['X-Mower-Mac'], isNotEmpty);

    lanReachable = true;
    await registry.update('MW-7K3Q9P', preferLan: true);
    expect(registry.activeRoute, 'lan');
    expect(service.cameraBaseUrl, 'http://192.168.1.5:8889');
    expect(service.cameraIceServersUrl, '', reason: 'LAN: host candidates only');
    expect(service.cameraHeaders(), isEmpty, reason: 'MediaMTX itself takes no pairing headers');

    // a QR with c= wins on every route
    lanReachable = false;
    await registry.pairFromText('$_backendQr&c=https://cam.example.com/');
    await registry.update('MW-7K3Q9P', preferLan: false);
    await _flush();
    expect(registry.activeRoute, 'relay');
    expect(service.cameraBaseUrl, 'https://cam.example.com');
    expect(service.cameraHeaders(), isEmpty, reason: 'an explicit camera URL is a plain media server');

    final legacy = PairedRobot.fromPairUrl(_legacyQr);
    expect(RobotRegistry.cameraBaseUrlFor(legacy, 'relay'), '');
    expect(RobotRegistry.cameraBaseUrlFor(legacy.copyWith(lanAddress: '10.0.0.5'), 'lan'), 'http://10.0.0.5:8889');
    service.dispose();
  });

  test('registry reads backend status and adopts the reported LAN address', () async {
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      if (req.url.path == '/v1/robots/MW-7K3Q9P/status') {
        return http.Response(
          jsonEncode({
            'robot_id': 'MW-7K3Q9P',
            'online': true,
            'last_seen': 1789600000,
            'lan': '192.168.1.77',
            'info': {'api_version': 2},
            'telemetry': null,
            'sessions': 0,
          }),
          200,
        );
      }
      return http.Response('{"error":"not found"}', 404);
    });
    final registry = RobotRegistry(
      rosbridge: service,
      store: MemoryPairingStore(),
      backend: BackendClient(client: client),
      lanProbe: (_, _) async => false,
    );
    await registry.load();
    await registry.pairFromText(_backendQr);
    await registry.refreshAll();
    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), 'https://api.mower.fxrbindi.com/v1/robots/MW-7K3Q9P/status');
    expect(requests.single.headers['X-Mower-Client'], registry.clientId);
    expect(requests.single.headers['X-Mower-Mac'], hasLength(64));
    final status = registry.statusOf('MW-7K3Q9P');
    expect(status?.online, isTrue);
    expect(status?.lastSeen?.millisecondsSinceEpoch, 1789600000 * 1000);
    expect(registry.active?.lanAddress, '192.168.1.77');

    // a legacy relay robot has no backend: nothing is asked
    await registry.pairFromText(_legacyQr);
    await registry.refreshAll();
    expect(requests, hasLength(1));
    service.dispose();
  });

  test('DEV_PAIR_URL pairs on first start only', () async {
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final store = MemoryPairingStore();
    final registry = RobotRegistry(
      rosbridge: service,
      store: store,
      backend: BackendClient(client: MockClient((_) async => http.Response('{}', 404))),
      lanProbe: (_, _) async => false,
      devPairUrl: _legacyQr,
    );
    await registry.load();
    expect(registry.robots.map((r) => r.id), ['MW-7K3Q9P']);
    await registry.remove('MW-7K3Q9P');

    // a second start keeps the user's choice: nothing is re-added
    final again = RobotRegistry(
      rosbridge: service,
      store: store,
      backend: BackendClient(client: MockClient((_) async => http.Response('{}', 404))),
      lanProbe: (_, _) async => false,
      devPairUrl: _legacyQr,
    );
    await again.load();
    expect(again.robots, isEmpty);
    service.dispose();
  });

  test('backend errors are surfaced, not thrown', () async {
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://unused',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final registry = RobotRegistry(
      rosbridge: service,
      store: MemoryPairingStore(),
      backend: BackendClient(client: MockClient((_) async => http.Response('{"error":"not paired"}', 401))),
      lanProbe: (_, _) async => false,
    );
    await registry.load();
    await registry.pairFromText(_backendQr);
    await registry.refreshAll();
    expect(registry.statusOf('MW-7K3Q9P'), isNull);
    expect(registry.statusErrorOf('MW-7K3Q9P'), 'not paired');
    service.dispose();
  });
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final Completer<void> _ready = Completer<void>();
  final StreamController<dynamic> _incoming = StreamController<dynamic>.broadcast(sync: true);
  final StreamController<dynamic> sent = StreamController<dynamic>.broadcast(sync: true);

  late final WebSocketSink _sink = _FakeWebSocketSink(sent);

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void addIncoming(dynamic value) => _incoming.add(value);

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._controller);

  final StreamController<dynamic> _controller;

  @override
  void add(dynamic data) => _controller.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
