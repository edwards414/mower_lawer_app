import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/mission_mock.dart';
import '../services/whep_client.dart';

/// Full-screen live camera view backed by a WebRTC (WHEP) pull stream from the
/// on-robot media server. Replaces the previous raw `sensor_msgs/Image` +
/// [RawImage] decode path. Reconnects automatically when [whepUrl] changes
/// (e.g. switching front/rear feed or the robot IP).
class WebrtcCameraView extends StatefulWidget {
  const WebrtcCameraView({
    super.key,
    required this.feed,
    required this.whepUrl,
  });

  final CameraFeed feed;

  /// WHEP endpoint for this feed, or empty when the robot IP is unknown.
  final String whepUrl;

  @override
  State<WebrtcCameraView> createState() => _WebrtcCameraViewState();
}

class _WebrtcCameraViewState extends State<WebrtcCameraView> {
  WhepClient? _client;
  WhepState _state = WhepState.idle;
  Timer? _retryTimer;
  int _retryAttempt = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(WebrtcCameraView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.whepUrl != widget.whepUrl) {
      unawaited(_restart(resetBackoff: true));
    }
  }

  Future<void> _restart({required bool resetBackoff}) async {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (resetBackoff) {
      _retryAttempt = 0;
    }
    final previous = _client;
    _client = null;
    await previous?.dispose();
    if (!mounted) {
      return;
    }
    _start();
  }

  void _start() {
    final url = widget.whepUrl;
    if (url.isEmpty) {
      setState(() => _state = WhepState.idle);
      return;
    }
    late final WhepClient client;
    client = WhepClient(
      whepUrl: url,
      onStateChanged: (state) {
        if (!mounted || _client != client) {
          return;
        }
        setState(() => _state = state);
        if (state == WhepState.connected) {
          _retryAttempt = 0;
          _retryTimer?.cancel();
          _retryTimer = null;
        } else if (state == WhepState.failed) {
          _scheduleRetry();
        }
      },
    );
    _client = client;
    setState(() => _state = WhepState.connecting);
    // Errors surface through onStateChanged (-> WhepState.failed).
    client.connect();
  }

  void _scheduleRetry() {
    if (_retryTimer != null || widget.whepUrl.isEmpty || !mounted) {
      return;
    }
    final seconds = (2 << _retryAttempt).clamp(2, 30).toInt();
    _retryAttempt = (_retryAttempt + 1).clamp(0, 4).toInt();
    _retryTimer = Timer(Duration(seconds: seconds), () {
      _retryTimer = null;
      if (mounted) {
        unawaited(_restart(resetBackoff: false));
      }
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _client?.dispose();
    _client = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final client = _client;
    if (client != null && _state == WhepState.connected) {
      return Stack(
        fit: StackFit.expand,
        children: [
          RTCVideoView(
            client.renderer,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x66000000),
                  Color(0x00000000),
                  Color(0x66000000),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return _CameraPlaceholder(
      feed: widget.feed,
      state: _state,
      hasUrl: widget.whepUrl.isNotEmpty,
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder({
    required this.feed,
    required this.state,
    required this.hasUrl,
  });

  final CameraFeed feed;
  final WhepState state;
  final bool hasUrl;

  @override
  Widget build(BuildContext context) {
    final title = feed == CameraFeed.front ? '前鏡頭' : '後鏡頭';
    final detail = !hasUrl
        ? '尚未設定機器人 IP'
        : switch (state) {
            WhepState.connecting => '影像連線中…',
            WhepState.failed => '影像連線失敗',
            _ => '等待影像串流',
          };
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFF111827)),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Color(0xFFECEFF1),
              size: 48,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Color(0xFFB0BEC5),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
