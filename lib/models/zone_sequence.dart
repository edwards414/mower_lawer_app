/// Where the robot's zone sequence (/run_zone_sequence) is, from the latched
/// JSON the coverage node publishes on /zone_sequence_status.
class ZoneSequenceStatus {
  const ZoneSequenceStatus({
    required this.state,
    required this.zoneIds,
    required this.index,
    required this.leg,
    this.zoneId,
    this.nextZoneId,
    this.message = '',
  });

  /// idle | running | completed | failed | canceled
  final String state;

  /// The zones in the order they are mowed.
  final List<int> zoneIds;

  /// Index into [zoneIds]: the zone being mowed, or the one a channel leaves.
  final int index;

  /// While running: `zone` (mowing [zoneId]) or `channel` (driving from
  /// [zoneId] to [nextZoneId]).
  final String leg;
  final int? zoneId;
  final int? nextZoneId;
  final String message;

  bool get running => state == 'running';

  static ZoneSequenceStatus? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final state = json['state'];
    if (state is! String) {
      return null;
    }
    final ids = json['zone_ids'];
    final leg = json['leg'];
    return ZoneSequenceStatus(
      state: state,
      zoneIds: ids is List
          ? ids.whereType<num>().map((id) => id.toInt()).toList()
          : const [],
      index: (json['index'] as num?)?.toInt() ?? 0,
      leg: leg is String ? leg : '',
      zoneId: (json['zone_id'] as num?)?.toInt(),
      nextZoneId: (json['next_zone_id'] as num?)?.toInt(),
      message: json['message']?.toString() ?? '',
    );
  }
}
