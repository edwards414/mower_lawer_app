import 'package:flutter/material.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';
import 'webrtc_camera_view.dart';

/// The front camera as a picture-in-picture that a tap enlarges, in its own
/// layer so video frames never repaint the rest of the page.
class FrontCameraPip extends StatelessWidget {
  const FrontCameraPip({
    super.key,
    required this.mission,
    required this.expanded,
    required this.banner,
    required this.onTap,
  });

  final MissionMockProvider mission;
  final bool expanded;

  /// Enlarged, the view spans the top of the screen (portrait): square at the
  /// top edge, rounded at the bottom.
  final bool banner;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final flush = expanded && banner;
    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeInOut,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF111827),
            borderRadius: flush
                ? const BorderRadius.vertical(bottom: Radius.circular(20))
                : BorderRadius.circular(20),
            // A white frame on a soft shadow, like the map's other panels.
            border: flush ? null : Border.all(color: Colors.white, width: 2.5),
            boxShadow: flush ? null : AppStyle.floatShadow,
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              WebrtcCameraView(
                feed: CameraFeed.front,
                whepUrl: mission.whepUrl(CameraFeed.front),
                authHeaders: mission.whepHeaders,
                iceServersUrl: mission.whepIceServersUrl,
                noUrlDetail: mission.cameraUnavailableReason,
                showStats: expanded,
              ),
              Positioned(
                right: 6,
                bottom: 6,
                child: Icon(
                  expanded ? AppIcons.minimize2 : AppIcons.maximize2,
                  color: Colors.white,
                  size: 16,
                  shadows: const [Shadow(color: Colors.black87, blurRadius: 4)],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
