/// One saved site (a named, geo-anchored snapshot of the whole zone set) as
/// published by the backend on `/site_list` and in `/site_op` `sites_json`.
class SiteInfo {
  const SiteInfo({
    required this.name,
    this.createdAt,
    this.updatedAt,
    this.zoneCount = 0,
    this.riskCount = 0,
    this.channelCount = 0,
    this.areaM2 = 0.0,
    this.datumSource = 'fallback',
  });

  final String name;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final int zoneCount;
  final int riskCount;
  final int channelCount;

  /// Total work-zone area in m².
  final double areaM2;

  /// 'navsat' (RTK/GPS datum) or 'fallback' (default datum).
  final String datumSource;

  factory SiteInfo.fromJson(Map<String, dynamic> json) {
    return SiteInfo(
      name: json['name']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
      zoneCount: (json['zone_count'] as num?)?.toInt() ?? 0,
      riskCount: (json['risk_count'] as num?)?.toInt() ?? 0,
      channelCount: (json['channel_count'] as num?)?.toInt() ?? 0,
      areaM2: (json['area_m2'] as num?)?.toDouble() ?? 0.0,
      datumSource: json['datum_source']?.toString() ?? 'fallback',
    );
  }
}
