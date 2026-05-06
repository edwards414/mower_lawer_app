import 'package:flutter/material.dart';

class BreathingMarker extends StatefulWidget {
  const BreathingMarker({super.key});

  @override
  State<BreathingMarker> createState() => _BreathingMarkerState();
}

class _BreathingMarkerState extends State<BreathingMarker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
    // Animate the shadow spread/blur or size
    _animation = Tween<double>(
      begin: 0.0,
      end: 10.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.orange.withValues(alpha: 0.6),
                blurRadius: _animation.value, // Breathing blur
                spreadRadius: _animation.value / 2, // Breathing spread
              ),
              const BoxShadow(
                color: Colors.black26,
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(Icons.agriculture, color: Colors.orange, size: 28),
        );
      },
    );
  }
}
