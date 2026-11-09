import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where the satellite map gets Google's tiles from, once a session is open.
@immutable
class GoogleTileSource {
  const GoogleTileSource({
    required this.urlTemplate,
    required this.headers,
    required this.maxNativeZoom,
    required this.copyright,
  });

  /// flutter_map template (`{z}/{x}/{y}`), session and key filled in.
  final String urlTemplate;

  /// Sent with every tile: says which app is asking, for a key restricted to
  /// this app.
  final Map<String, String> headers;

  /// The deepest zoom Google has real imagery for at the site; deeper zooms
  /// scale these tiles up.
  final int maxNativeZoom;

  /// Google's data attribution for the site. It must be shown in full.
  final String copyright;
}

/// Google satellite tiles (Map Tiles API, 2D) for the satellite base map.
///
/// Sharper than the NLSC orthophoto where Google has aerial imagery (z20-21
/// in many Taiwanese towns, against NLSC's z19). It needs an API key with the
/// Map Tiles API enabled, given at build time and kept out of git:
///
///     flutter run --dart-define-from-file=dart_defines.local.json
///
/// with `{"GOOGLE_MAPS_API_KEY": "..."}` in that (git-ignored) file. With no
/// key, or when Google cannot be reached, the map keeps the NLSC tiles.
class GoogleMapTiles {
  GoogleMapTiles({
    String apiKey = const String.fromEnvironment('GOOGLE_MAPS_API_KEY'),
    http.Client? client,
    Future<Map<String, String>> Function()? appHeaders,
    DateTime Function()? now,
  }) : _apiKey = apiKey.trim(),
       _client = client,
       _appHeaders = appHeaders ?? _platformAppHeaders,
       _now = now ?? DateTime.now;

  /// The app's instance, with the key the build was given.
  static final GoogleMapTiles shared = GoogleMapTiles();

  static const String _host = 'tile.googleapis.com';
  static const String _sessionPref = 'google_tiles_session';
  static const String _expiryPref = 'google_tiles_session_expiry';
  static const String _keyPref = 'google_tiles_session_key';

  /// A session lasts about two weeks; a new one is opened when less than this
  /// is left, so it never lapses while the map is up.
  static const Duration _renewBefore = Duration(days: 1);

  final String _apiKey;
  final http.Client? _client;
  final Future<Map<String, String>> Function() _appHeaders;
  final DateTime Function() _now;

  bool get configured => _apiKey.isNotEmpty;

  /// Google's tiles for [area], or null when there is no key or Google
  /// refused (the reason goes to the debug log).
  Future<GoogleTileSource?> sourceFor(LatLngBounds area) async {
    if (!configured) return null;
    final client = _client ?? http.Client();
    try {
      final headers = await _appHeaders();
      for (final fresh in const [false, true]) {
        final session = await _session(client, headers, forceNew: fresh);
        if (session == null) return null;
        final viewport = await _viewport(client, headers, session, area);
        if (viewport == null) {
          // A cached session Google no longer takes: open a new one, once.
          if (!fresh) continue;
          return null;
        }
        final (copyright, maxZoom) = viewport;
        return GoogleTileSource(
          urlTemplate:
              'https://$_host/v1/2dtiles/{z}/{x}/{y}'
              '?session=$session&key=$_apiKey',
          headers: headers,
          maxNativeZoom: maxZoom,
          copyright: copyright,
        );
      }
      return null;
    } catch (e) {
      debugPrint('Google tiles unavailable: $e');
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  /// The cached session while it has a day left, else a new one.
  Future<String?> _session(
    http.Client client,
    Map<String, String> headers, {
    required bool forceNew,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final keyTag = _keyTag;
    if (!forceNew && prefs.getString(_keyPref) == keyTag) {
      final cached = prefs.getString(_sessionPref);
      final expiry = prefs.getInt(_expiryPref);
      if (cached != null &&
          expiry != null &&
          DateTime.fromMillisecondsSinceEpoch(
            expiry * 1000,
          ).isAfter(_now().add(_renewBefore))) {
        return cached;
      }
    }
    final response = await client
        .post(
          Uri.https(_host, '/v1/createSession', {'key': _apiKey}),
          headers: {...headers, 'Content-Type': 'application/json'},
          body: jsonEncode({
            'mapType': 'satellite',
            'language': 'zh-TW',
            'region': 'TW',
          }),
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      debugPrint(
        'Google tiles: createSession ${response.statusCode} '
        '${_errorMessage(response.body)}',
      );
      return null;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final session = json['session'] as String?;
    final expiry = int.tryParse('${json['expiry']}');
    if (session == null || session.isEmpty) return null;
    await prefs.setString(_sessionPref, session);
    await prefs.setString(_keyPref, keyTag);
    if (expiry != null) {
      await prefs.setInt(_expiryPref, expiry);
    } else {
      await prefs.remove(_expiryPref);
    }
    return session;
  }

  /// The copyright and deepest zoom for [area], or null when Google refused
  /// the session.
  Future<(String, int)?> _viewport(
    http.Client client,
    Map<String, String> headers,
    String session,
    LatLngBounds area,
  ) async {
    final response = await client
        .get(
          Uri.https(_host, '/tile/v1/viewport', {
            'session': session,
            'key': _apiKey,
            'zoom': '19',
            'north': '${area.north}',
            'south': '${area.south}',
            'east': '${area.east}',
            'west': '${area.west}',
          }),
          headers: headers,
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      debugPrint(
        'Google tiles: viewport ${response.statusCode} '
        '${_errorMessage(response.body)}',
      );
      return null;
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final copyright = (json['copyright'] as String?)?.trim() ?? '';
    return (copyright, maxZoomAt(json['maxZoomRects'], area.center));
  }

  /// The deepest zoom of the rectangles that hold [point]: they overlap, a
  /// coarse one for the region and finer ones where there is aerial imagery.
  @visibleForTesting
  static int maxZoomAt(Object? rects, LatLng point) {
    var best = 0;
    if (rects is List) {
      for (final r in rects.whereType<Map<String, dynamic>>()) {
        final zoom = (r['maxZoom'] as num?)?.toInt();
        final n = (r['north'] as num?)?.toDouble();
        final s = (r['south'] as num?)?.toDouble();
        final e = (r['east'] as num?)?.toDouble();
        final w = (r['west'] as num?)?.toDouble();
        if (zoom == null || n == null || s == null || e == null || w == null) {
          continue;
        }
        final inside =
            point.latitude <= n &&
            point.latitude >= s &&
            point.longitude <= e &&
            point.longitude >= w;
        if (inside && zoom > best) best = zoom;
      }
    }
    // Nothing said: Google's usual depth for satellite.
    return best == 0 ? 20 : best.clamp(16, 22);
  }

  /// Ties a cached session to the key it was opened with.
  String get _keyTag =>
      _apiKey.length <= 6 ? _apiKey : _apiKey.substring(_apiKey.length - 6);

  static String _errorMessage(String body) {
    try {
      final error = (jsonDecode(body) as Map<String, dynamic>)['error'];
      if (error is Map<String, dynamic>) return '${error['message']}';
    } catch (_) {}
    return body.length > 160 ? body.substring(0, 160) : body;
  }

  /// Names the app to Google, so a key can be restricted to it.
  static Future<Map<String, String>> _platformAppHeaders() async {
    try {
      final id = (await PackageInfo.fromPlatform()).packageName;
      if (id.isEmpty) return const {};
      return switch (defaultTargetPlatform) {
        TargetPlatform.iOS => {'X-Ios-Bundle-Identifier': id},
        TargetPlatform.android => {'X-Android-Package': id},
        _ => const {},
      };
    } catch (_) {
      return const {};
    }
  }
}
