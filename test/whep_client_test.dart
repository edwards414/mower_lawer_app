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

  test('ICE gathering timeout fails instead of posting a partial offer', () {
    final peer = _FakePeerConnection(
      state: RTCIceGatheringState.RTCIceGatheringStateGathering,
      localDescription: RTCSessionDescription('v=0\r\n', 'offer'),
    );

    expect(
      waitForWhepIceGathering(peer, timeout: const Duration(milliseconds: 5)),
      throwsA(isA<TimeoutException>()),
    );
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
