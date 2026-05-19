import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class IPhone12Template extends StatelessWidget {
  const IPhone12Template({super.key, required this.child});

  static const Size logicalSize = Size(390, 844);
  static const double devicePixelRatio = 3;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (!_shouldUseTemplate(media.size)) {
      return child;
    }

    final scale = math
        .min(
          (media.size.width - 48) / _IPhone12Frame.outerSize.width,
          (media.size.height - 48) / _IPhone12Frame.outerSize.height,
        )
        .clamp(0.55, 1.0);

    return ColoredBox(
      color: const Color(0xFFECEFF1),
      child: Center(
        child: SizedBox(
          width: _IPhone12Frame.outerSize.width * scale,
          height: _IPhone12Frame.outerSize.height * scale,
          child: FittedBox(
            fit: BoxFit.contain,
            child: _IPhone12Frame(child: child),
          ),
        ),
      ),
    );
  }

  bool _shouldUseTemplate(Size size) {
    if (size.width < 520 || size.height < 720) {
      return false;
    }

    if (kIsWeb) {
      return true;
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => true,
      TargetPlatform.android ||
      TargetPlatform.fuchsia ||
      TargetPlatform.iOS => false,
    };
  }
}

class _IPhone12Frame extends StatelessWidget {
  const _IPhone12Frame({required this.child});

  static const double _frameInset = 12;
  static const Size outerSize = Size(414, 868);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: outerSize.width,
      height: outerSize.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0D0F),
          borderRadius: BorderRadius.circular(58),
          boxShadow: const [
            BoxShadow(
              color: Color(0x3D000000),
              blurRadius: 34,
              offset: Offset(0, 18),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(_frameInset),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(45),
            child: Stack(
              fit: StackFit.expand,
              children: [
                MediaQuery(
                  data: _iphone12MediaQuery(context),
                  child: SizedBox.fromSize(
                    size: IPhone12Template.logicalSize,
                    child: child,
                  ),
                ),
                const IgnorePointer(child: _IPhone12Notch()),
                const IgnorePointer(child: _IPhone12HomeIndicator()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  MediaQueryData _iphone12MediaQuery(BuildContext context) {
    return MediaQuery.of(context).copyWith(
      size: IPhone12Template.logicalSize,
      devicePixelRatio: IPhone12Template.devicePixelRatio,
      padding: const EdgeInsets.only(top: 47, bottom: 34),
      viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
      viewInsets: EdgeInsets.zero,
    );
  }
}

class _IPhone12Notch extends StatelessWidget {
  const _IPhone12Notch();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: Container(
        width: 210,
        height: 31,
        decoration: const BoxDecoration(
          color: Color(0xFF0A0D0F),
          borderRadius: BorderRadius.only(
            bottomLeft: Radius.circular(18),
            bottomRight: Radius.circular(18),
          ),
        ),
      ),
    );
  }
}

class _IPhone12HomeIndicator extends StatelessWidget {
  const _IPhone12HomeIndicator();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Container(
          width: 132,
          height: 5,
          decoration: BoxDecoration(
            color: const Color(0xCC111111),
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }
}
