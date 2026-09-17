import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/models/paired_robot.dart';
import 'package:mower_stdio/providers/robot_registry.dart';
import 'package:mower_stdio/services/pairing_auth.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';

// Shared with mower_path_planning src/mower_mission/test/test_pairing.py
const _vectorSecret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 20 zero bytes
const _vectorRobot = 'MW-7K3Q9P';
const _vectorClient = 'iphone-1234';
const _vectorT = 1789600000;
const _vectorNonce = '00112233445566778899aabbccddeeff';
const _vectorMac =
    'd33d2137cf8c6bb75ba80ff22b9afbf32a09f2346e83617e41e96026aa2cfd42';

const _qr =
    'https://mower.fxrbindi.com/pair?v=1&id=MW-7K3Q9P&s=$_vectorSecret'
    '&n=%E5%89%8D%E9%99%A2&h=wss%3A%2F%2Fcontrol.example.com&l=192.168.0.113';

void main() {
  test('base32 decode and HMAC match the robot-side vector', () {
    expect(PairingAuth.base32Decode(_vectorSecret), List.filled(20, 0));
    expect(PairingAuth.base32Decode('MZXW6YTBOI======'), utf8.encode('foobar'));
    expect(
      PairingAuth.computeMac(
        secret: _vectorSecret,
        robotId: _vectorRobot,
        clientId: _vectorClient,
        unixSeconds: _vectorT,
        nonce: _vectorNonce,
      ),
      _vectorMac,
    );
  });

  test('headers carry the hand-shake with a fresh nonce', () {
    final robot = PairedRobot.fromPairUrl(_qr);
    final h = PairingAuth.headers(
      robot,
      _vectorClient,
      now: DateTime.fromMillisecondsSinceEpoch(_vectorT * 1000),
      nonce: _vectorNonce,
    );
    expect(h[PairingAuth.headerRobot], _vectorRobot);
    expect(h[PairingAuth.headerClient], _vectorClient);
    expect(h[PairingAuth.headerTime], '$_vectorT');
    expect(h[PairingAuth.headerNonce], _vectorNonce);
    expect(h[PairingAuth.headerMac], _vectorMac);
    final a = PairingAuth.headers(robot, _vectorClient);
    final b = PairingAuth.headers(robot, _vectorClient);
    expect(a[PairingAuth.headerNonce], isNot(b[PairingAuth.headerNonce]));
  });

  test('QR payload parses, bad payloads are rejected', () {
    final r = PairedRobot.fromPairUrl(_qr);
    expect(r.id, 'MW-7K3Q9P');
    expect(r.name, '前院');
    expect(r.relayUrl, 'wss://control.example.com');
    expect(r.lanAddress, '192.168.0.113');
    expect(r.preferLan, isFalse);
    expect(r.preferredUrl, 'wss://control.example.com');
    expect(r.copyWith(preferLan: true).preferredUrl, 'ws://192.168.0.113:9090');

    final lanOnly = PairedRobot.fromPairUrl('id=MW-ABC123&s=$_vectorSecret&l=10.0.0.5');
    expect(lanOnly.preferLan, isTrue);
    expect(lanOnly.preferredUrl, 'ws://10.0.0.5:9090');
    expect(lanOnly.displayName, 'MW-ABC123');

    expect(() => PairedRobot.fromPairUrl('hello'), throwsFormatException);
    expect(() => PairedRobot.fromPairUrl('https://x/pair?id=nope&s=$_vectorSecret'),
        throwsFormatException);
    expect(() => PairedRobot.fromPairUrl('https://x/pair?id=MW-7K3Q9P&s=short'),
        throwsFormatException);
    expect(() => PairedRobot.fromPairUrl('https://x/pair?id=MW-7K3Q9P&s=$_vectorSecret&h=http://x'),
        throwsFormatException);

    final json = jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>;
    final back = PairedRobot.fromJson(json);
    expect(back.id, r.id);
    expect(back.secret, r.secret);
    expect(back.relayUrl, r.relayUrl);
  });

  test('registry persists robots, selects one and points rosbridge at it', () async {
    final channel = _FakeWebSocketChannel();
    final uris = <Uri>[];
    final headerSets = <Map<String, dynamic>>[];
    final service = RosbridgeService(
      url: 'ws://default.test:9090',
      connector: (uri, {headers = const <String, dynamic>{}}) {
        uris.add(uri);
        headerSets.add(headers);
        return channel;
      },
    );
    final store = MemoryPairingStore();
    final registry = RobotRegistry(rosbridge: service, store: store);
    await registry.load();
    expect(registry.robots, isEmpty);
    expect(registry.clientId, startsWith('ios-'));

    final robot = await registry.pairFromText(_qr);
    expect(registry.active?.id, robot.id);
    expect(uris.last.toString(), 'wss://control.example.com');
    expect(headerSets.last[PairingAuth.headerRobot], 'MW-7K3Q9P');
    expect(headerSets.last[PairingAuth.headerMac], hasLength(64));

    await registry.update(robot.id, preferLan: true);
    expect(uris.last.toString(), 'ws://192.168.0.113:9090');

    // a second app start reads the same robots and client id back
    final again = RobotRegistry(rosbridge: service, store: store);
    await again.load();
    expect(again.robots.single.id, 'MW-7K3Q9P');
    expect(again.active?.preferLan, isTrue);
    expect(again.clientId, registry.clientId);

    // identity check against /robot/info
    again.noteReportedRobotId('MW-7K3Q9P');
    expect(again.identityMismatch, isFalse);
    again.noteReportedRobotId('MW-OTHER1');
    expect(again.identityMismatch, isTrue);

    await again.remove('MW-7K3Q9P');
    expect(again.robots, isEmpty);
    expect(again.active, isNull);

    service.dispose();
  });
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final Completer<void> _ready = Completer<void>();
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast(sync: true);
  final StreamController<dynamic> sent = StreamController<dynamic>.broadcast(
    sync: true,
  );

  late final WebSocketSink _sink = _FakeWebSocketSink(sent);

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
  Future<void> close([int? closeCode, String? closeReason]) =>
      _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
