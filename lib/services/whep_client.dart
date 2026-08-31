import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import 'remote_access_config.dart';
import 'whep_http_client_factory.dart';

enum WhepState { idle, connecting, connected, failed }

const _defaultIceGatheringTimeout = Duration(seconds: 8);
const _defaultSignalingTimeout = Duration(seconds: 12);
const _defaultTeardownTimeout = Duration(seconds: 4);

@visibleForTesting
Future<void> waitForWhepIceGathering(
  RTCPeerConnection peerConnection, {
  Duration timeout = _defaultIceGatheringTimeout,
}) async {
  if (await peerConnection.getIceGatheringState() ==
      RTCIceGatheringState.RTCIceGatheringStateComplete) {
    return;
  }

  final completed = Completer<void>();
  final previousHandler = peerConnection.onIceGatheringState;
  late final Function(RTCIceGatheringState state) handler;
  handler = (state) {
    previousHandler?.call(state);
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !completed.isCompleted) {
      completed.complete();
    }
  };
  peerConnection.onIceGatheringState = handler;
  try {
    // Close the race between the initial state check and installing the
    // callback. WHEP uses one-shot SDP unless PATCH trickle ICE is implemented,
    // so a candidate-complete local description is required before POST.
    if (await peerConnection.getIceGatheringState() !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await completed.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          'WHEP ICE gathering did not complete',
          timeout,
        ),
      );
    }
  } finally {
    if (identical(peerConnection.onIceGatheringState, handler)) {
      peerConnection.onIceGatheringState = previousHandler;
    }
  }
}

@visibleForTesting
Future<String> latestWhepLocalDescriptionSdp(
  RTCPeerConnection peerConnection,
) async {
  final description = await peerConnection.getLocalDescription();
  final sdp = description?.sdp;
  if (sdp == null || sdp.trim().isEmpty) {
    throw StateError('WHEP local SDP is unavailable after ICE gathering');
  }
  return sdp;
}

@visibleForTesting
Future<http.Response> postWhepOffer({
  required http.Client client,
  required Uri uri,
  required Map<String, String> headers,
  required String sdp,
  Duration timeout = _defaultSignalingTimeout,
}) {
  return client
      .post(uri, headers: headers, body: sdp)
      .timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('WHEP signaling POST timed out', timeout),
      );
}

@visibleForTesting
Future<http.Response> deleteWhepSession({
  required http.Client client,
  required Uri uri,
  required Map<String, String> headers,
  Duration timeout = _defaultTeardownTimeout,
}) {
  return client
      .delete(uri, headers: headers)
      .timeout(
        timeout,
        onTimeout: () =>
            throw TimeoutException('WHEP session DELETE timed out', timeout),
      );
}

/// Minimal WHEP (WebRTC-HTTP Egress Protocol) client that pulls a single
/// receive-only video stream from a media server such as MediaMTX.
///
/// Signaling is a single HTTP POST of the local SDP offer; the server replies
/// with the SDP answer (HTTP 201/200) and a `Location` header pointing at the
/// session resource, which we DELETE on teardown. MediaMTX embeds its server
/// candidates in the answer; Cloudflare STUN helps the client traverse mobile
/// and Wi-Fi NATs when connecting over the Internet.
class WhepClient {
  WhepClient({
    required this.whepUrl,
    http.Client? httpClient,
    this.onStateChanged,
    this.iceGatheringTimeout = _defaultIceGatheringTimeout,
    this.signalingTimeout = _defaultSignalingTimeout,
    this.teardownTimeout = _defaultTeardownTimeout,
  }) : _httpClient = httpClient ?? createWhepHttpClient();

  final String whepUrl;
  final ValueChanged<WhepState>? onStateChanged;
  final Duration iceGatheringTimeout;
  final Duration signalingTimeout;
  final Duration teardownTimeout;

  final RTCVideoRenderer renderer = RTCVideoRenderer();
  final http.Client _httpClient;
  RTCPeerConnection? _pc;
  String? _resourceUrl;
  bool _rendererInitialized = false;
  bool _httpClientClosed = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  WhepState _state = WhepState.idle;

  WhepState get state => _state;

  void _setState(WhepState next) {
    if (_disposed || _state == next) {
      return;
    }
    _state = next;
    onStateChanged?.call(next);
  }

  Future<void> connect() async {
    if (_disposed) {
      return;
    }
    _setState(WhepState.connecting);
    try {
      await renderer.initialize();
      _rendererInitialized = true;
      if (_disposed) {
        await _cleanupTransport(deleteRemoteSession: true);
        return;
      }
      final pc = await createPeerConnection({
        'iceServers': <Map<String, dynamic>>[
          {
            'urls': <String>['stun:stun.cloudflare.com:3478'],
          },
        ],
        'sdpSemantics': 'unified-plan',
      });
      if (_disposed) {
        await pc.close();
        await _cleanupTransport(deleteRemoteSession: true);
        return;
      }
      _pc = pc;

      pc.onTrack = (RTCTrackEvent event) {
        if (event.streams.isNotEmpty) {
          renderer.srcObject = event.streams.first;
        }
      };
      pc.onConnectionState = (RTCPeerConnectionState state) {
        switch (state) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _setState(WhepState.connected);
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _setState(WhepState.failed);
            break;
          default:
            break;
        }
      };

      // Receive-only: we consume the robot's camera, we never publish.
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitForWhepIceGathering(pc, timeout: iceGatheringTimeout);
      if (_disposed) {
        await _cleanupTransport(deleteRemoteSession: true);
        return;
      }
      final localSdp = await latestWhepLocalDescriptionSdp(pc);

      final response = await postWhepOffer(
        client: _httpClient,
        uri: Uri.parse(whepUrl),
        headers: {
          ...RemoteAccessConfig.cloudflareAccessHeaders,
          'Content-Type': 'application/sdp',
        },
        sdp: localSdp,
        timeout: signalingTimeout,
      );
      if (response.statusCode != 201 && response.statusCode != 200) {
        throw StateError('WHEP signaling failed: HTTP ${response.statusCode}');
      }

      final location = response.headers['location'];
      if (location != null && location.isNotEmpty) {
        _resourceUrl = Uri.parse(whepUrl).resolve(location).toString();
      }
      if (_disposed) {
        await _cleanupTransport(deleteRemoteSession: true);
        return;
      }

      await pc.setRemoteDescription(
        RTCSessionDescription(response.body, 'answer'),
      );
    } catch (error, stack) {
      await _cleanupTransport(deleteRemoteSession: true);
      _closeHttpClient();
      if (!_disposed) {
        debugPrint('WhepClient.connect error: $error\n$stack');
        _setState(WhepState.failed);
      }
    }
  }

  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    _disposed = true;
    await _cleanupTransport(deleteRemoteSession: true);
    _closeHttpClient();
  }

  Future<void> _cleanupTransport({required bool deleteRemoteSession}) async {
    final resource = _resourceUrl;
    _resourceUrl = null;
    if (deleteRemoteSession && resource != null && !_httpClientClosed) {
      // Best-effort session teardown so the server frees the reader promptly.
      try {
        await deleteWhepSession(
          client: _httpClient,
          uri: Uri.parse(resource),
          headers: RemoteAccessConfig.cloudflareAccessHeaders,
          timeout: teardownTimeout,
        );
      } catch (_) {}
    }
    final pc = _pc;
    _pc = null;
    try {
      await pc?.close();
    } catch (_) {}
    if (_rendererInitialized) {
      _rendererInitialized = false;
      renderer.srcObject = null;
      try {
        await renderer.dispose();
      } catch (_) {}
    }
  }

  void _closeHttpClient() {
    if (_httpClientClosed) {
      return;
    }
    _httpClientClosed = true;
    _httpClient.close();
  }
}
