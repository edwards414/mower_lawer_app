import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:mower_stdio/services/whep_client.dart';

void main() {
  test('waits for ICE completion and reads the latest local SDP', () async {
    final peer = _FakePeerConnection(
      state: RTCIceGatheringState.RTCIceGatheringStateGathering,
      localDescription: RTCSessionDescription(
        'v=0\r\na=candidate:latest\r\n',
        'offer',
      ),
    );

    final gathering = waitForWhepIceGathering(
      peer,
      timeout: const Duration(seconds: 1),
    );
    await Future<void>.delayed(Duration.zero);
    peer.emitIceState(RTCIceGatheringState.RTCIceGatheringStateComplete);
    await gathering;

    expect(await latestWhepLocalDescriptionSdp(peer), contains('candidate'));
  });

  test('ICE gathering timeout proceeds once a host candidate exists', () async {
    // On a LAN the host candidate is all MediaMTX needs; a STUN server that
    // never answers must not block the camera.
    final peer = _FakePeerConnection(
      state: RTCIceGatheringState.RTCIceGatheringStateGathering,
      localDescription: RTCSessionDescription(
        'v=0\r\na=candidate:1 1 udp 2130706431 192.168.1.20 51000 typ host\r\n',
        'offer',
      ),
    );
    await waitForWhepIceGathering(peer, timeout: const Duration(milliseconds: 20));
    expect(await latestWhepLocalDescriptionSdp(peer), contains('typ host'));
  });

  test('ICE gathering timeout without any candidate still fails', () {
    final peer = _FakePeerConnection(
      state: RTCIceGatheringState.RTCIceGatheringStateGathering,
      localDescription: RTCSessionDescription('v=0\r\n', 'offer'),
    );
    expect(
      waitForWhepIceGathering(peer, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('LAN hosts use no STUN server, public hosts keep it', () {
    expect(iceServersForWhepUrl('http://192.168.0.109:8889/front/whep'), isEmpty);
    expect(iceServersForWhepUrl('http://10.77.0.2:8889/front/whep'), isEmpty);
    expect(iceServersForWhepUrl('http://172.20.1.9:8889/front/whep'), isEmpty);
    expect(iceServersForWhepUrl('http://mower.local:8889/front/whep'), isEmpty);
    expect(iceServersForWhepUrl('https://camera.example.com/front/whep'), isNotEmpty);
    expect(iceServersForWhepUrl('http://100.67.138.19:8889/front/whep'), isNotEmpty);
  });

  test('WHEP POST sends SDP and enforces its timeout', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        'v=0\r\nanswer',
        201,
        headers: {'location': '/front/session/1'},
      );
    });

    final response = await postWhepOffer(
      client: client,
      uri: Uri.parse('https://camera.test/front/whep'),
      headers: const {'Content-Type': 'application/sdp'},
      sdp: 'v=0\r\na=candidate:latest\r\n',
      timeout: const Duration(seconds: 1),
    );
    expect(response.statusCode, 201);
    expect(captured.body, contains('candidate:latest'));
    expect(captured.headers['content-type'], 'application/sdp');
    client.close();

    final pending = Completer<http.Response>();
    final stalledClient = MockClient((_) => pending.future);
    await expectLater(
      postWhepOffer(
        client: stalledClient,
        uri: Uri.parse('https://camera.test/front/whep'),
        headers: const {},
        sdp: 'v=0',
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete(http.Response('', 500));
    stalledClient.close();
  });

  test('ICE servers come from the backend /turn endpoint', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        '{"iceServers":[{"urls":["stun:stun.cloudflare.com:3478"]},'
        '{"urls":["turn:turn.cloudflare.com:3478?transport=udp","turns:turn.cloudflare.com:443?transport=tcp"],'
        '"username":"u","credential":"p"}],"expires_at":1}',
        200,
      );
    });
    final servers = await fetchIceServers(
      client: client,
      uri: Uri.parse('https://api.test/v1/robots/MW-1/turn'),
      headers: const {'X-Mower-Robot': 'MW-1'},
    );
    expect(captured.headers['X-Mower-Robot'], 'MW-1');
    expect(servers, hasLength(2));
    expect(servers[1]['username'], 'u');
    expect(servers[1]['credential'], 'p');
    expect(servers[1]['urls'], contains('turns:turn.cloudflare.com:443?transport=tcp'));

    final failing = MockClient((_) async => http.Response('{"error":"not paired"}', 401));
    await expectLater(
      fetchIceServers(client: failing, uri: Uri.parse('https://api.test/turn')),
      throwsA(isA<StateError>()),
    );
  });

  test('WHEP DELETE timeout is bounded for reconnect cleanup', () async {
    final pending = Completer<http.Response>();
    final client = MockClient((_) => pending.future);

    await expectLater(
      deleteWhepSession(
        client: client,
        uri: Uri.parse('https://camera.test/front/session/1'),
        headers: const {},
        timeout: const Duration(milliseconds: 5),
      ),
      throwsA(isA<TimeoutException>()),
    );
    pending.complete(http.Response('', 204));
    client.close();
  });

  test('WhepClient uses and closes an injected HTTP client', () async {
    final client = _TrackingClient();
    final whep = WhepClient(
      whepUrl: 'https://camera.test/front/whep',
      httpClient: client,
    );

    await whep.dispose();

    expect(client.closed, isTrue);
  });
}

class _TrackingClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    throw StateError('No request expected in this test');
  }

  @override
  void close() {
    closed = true;
  }
}

class _FakePeerConnection implements RTCPeerConnection {
  _FakePeerConnection({required this.state, this.localDescription});

  RTCIceGatheringState state;
  RTCSessionDescription? localDescription;

  @override
  Function(RTCIceGatheringState state)? onIceGatheringState;

  @override
  RTCIceGatheringState? get iceGatheringState => state;

  @override
  Future<RTCIceGatheringState?> getIceGatheringState() async => state;

  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      localDescription;

  void emitIceState(RTCIceGatheringState next) {
    state = next;
    onIceGatheringState?.call(next);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
