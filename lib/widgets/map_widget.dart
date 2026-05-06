import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/coverage_path.dart';
import '../models/mower_status.dart';
import 'breathing_marker.dart';

/// App Constants
class MapConstants {
  static const double defaultZoom = 18.0;
  static const String tileUrl =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String packageName = 'com.example.mower_stdio';
}

/// Map component showing OpenStreetMap with coverage path and mower position
class MapWidget extends StatefulWidget {
  final MowerStatus status;
  final CoveragePath coveragePath;

  const MapWidget({
    super.key,
    required this.status,
    required this.coveragePath,
  });

  @override
  State<MapWidget> createState() => _MapWidgetState();
}

class _MapWidgetState extends State<MapWidget> {
  final MapController _mapController = MapController();
  final bool _shouldFollowMower = true;

  @override
  void didUpdateWidget(covariant MapWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldFollowMower &&
        (widget.status.latitude != oldWidget.status.latitude ||
            widget.status.longitude != oldWidget.status.longitude)) {
      _mapController.move(
        LatLng(widget.status.latitude, widget.status.longitude),
        _mapController.camera.zoom,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Convert path points to LatLng
    final pathPoints = widget.coveragePath.pathPoints
        .map((p) => LatLng(p.latitude, p.longitude))
        .toList();

    // Convert covered polygons to LatLng lists
    final coveredPolygons = widget.coveragePath.coveredPolygons
        .map(
          (poly) => poly.map((p) => LatLng(p.latitude, p.longitude)).toList(),
        )
        .toList();

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: LatLng(
              widget.status.latitude,
              widget.status.longitude,
            ),
            initialZoom: MapConstants.defaultZoom,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
          ),
          children: [
            // Background
            Container(color: const Color(0xFFE0E0E0)), // Light grey background
            // Covered area (Polygons)
            if (coveredPolygons.isNotEmpty)
              PolygonLayer(
                polygons: coveredPolygons
                    .map(
                      (points) => Polygon(
                        points: points,
                        color: Colors.green.withValues(alpha: 0.3),
                        borderStrokeWidth: 0,
                      ),
                    )
                    .toList(),
              ),

            // Planned Path (Polyline)
            if (pathPoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: pathPoints,
                    strokeWidth: 2.0,
                    color: Colors.blueAccent.withValues(alpha: 0.7),
                  ),
                ],
              ),
            // Start & Current Position Markers
            MarkerLayer(
              markers: [
                // Start Point
                Marker(
                  point: LatLng(
                    widget.status.startLatitude,
                    widget.status.startLongitude,
                  ),
                  width: 32,
                  height: 32,
                  child: const Icon(
                    Icons.flag,
                    color: Colors.redAccent,
                    size: 32,
                  ),
                ),
                // Current Position
                Marker(
                  point: LatLng(
                    widget.status.latitude,
                    widget.status.longitude,
                  ),
                  width: 40,
                  height: 40,
                  child: const BreathingMarker(),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
