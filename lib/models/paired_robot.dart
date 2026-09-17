/// A robot this phone has paired with by scanning its QR code
/// (mower_path_planning docs/ROBOT_API.md, "配對").
///
/// The QR payload is a URL such as
/// `https://mower.fxrbindi.com/pair?v=1&id=MW-7K3Q9P&s=SECRET&n=NAME&h=RELAY&l=LAN`;
/// `id` + `s` are mandatory; the rest can be edited in the app later.
class PairedRobot {
  const PairedRobot({
    required this.id,
    required this.secret,
    this.name = '',
    this.relayUrl = '',
    this.lanAddress = '',
    this.cameraUrl = '',
    this.preferLan = false,
    this.pairedAt,
  });

  static final RegExp idPattern = RegExp(r'^MW-[A-Z0-9]{6}$');
  static const int rosbridgePort = 9090;

  final String id;

  /// base32 pairing secret from the QR (never shown in the UI).
  final String secret;
  final String name;

  /// `wss://control.example.com` — empty when the robot has no relay.
  final String relayUrl;

  /// LAN IP or host of the robot, editable (DHCP changes it).
  final String lanAddress;

  /// Optional WHEP base URL override (`c` in the QR); empty = derive.
  final String cameraUrl;

  /// Connect over the LAN instead of the relay.
  final bool preferLan;
  final DateTime? pairedAt;

  String get displayName => name.isNotEmpty ? name : id;
  bool get hasRelay => relayUrl.isNotEmpty;
  bool get hasLan => lanAddress.isNotEmpty;

  String get lanUrl => hasLan ? 'ws://$lanAddress:$rosbridgePort' : '';

  /// The rosbridge URL to use right now, or empty if nothing is configured.
  String get preferredUrl {
    if (preferLan && hasLan) return lanUrl;
    if (hasRelay) return relayUrl;
    return lanUrl;
  }

  bool get usesLan => preferredUrl == lanUrl && hasLan;

  PairedRobot copyWith({
    String? name,
    String? relayUrl,
    String? lanAddress,
    String? cameraUrl,
    bool? preferLan,
    String? secret,
  }) {
    return PairedRobot(
      id: id,
      secret: secret ?? this.secret,
      name: name ?? this.name,
      relayUrl: relayUrl ?? this.relayUrl,
      lanAddress: lanAddress ?? this.lanAddress,
      cameraUrl: cameraUrl ?? this.cameraUrl,
      preferLan: preferLan ?? this.preferLan,
      pairedAt: pairedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'secret': secret,
    'name': name,
    'relay_url': relayUrl,
    'lan_address': lanAddress,
    'camera_url': cameraUrl,
    'prefer_lan': preferLan,
    'paired_at': pairedAt?.toUtc().toIso8601String(),
  };

  factory PairedRobot.fromJson(Map<String, dynamic> j) => PairedRobot(
    id: j['id']?.toString() ?? '',
    secret: j['secret']?.toString() ?? '',
    name: j['name']?.toString() ?? '',
    relayUrl: j['relay_url']?.toString() ?? '',
    lanAddress: j['lan_address']?.toString() ?? '',
    cameraUrl: j['camera_url']?.toString() ?? '',
    preferLan: j['prefer_lan'] == true,
    pairedAt: DateTime.tryParse(j['paired_at']?.toString() ?? ''),
  );

  /// Parse the QR payload / pasted text. Accepts the https form, a
  /// `mower://pair?...` form or a bare query string. Throws [FormatException]
  /// with a user-facing message.
  static PairedRobot fromPairUrl(String text, {DateTime? now}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('沒有內容');
    }
    Map<String, String> params;
    final uri = Uri.tryParse(trimmed);
    if (uri != null && uri.hasQuery && (uri.path.endsWith('pair') || uri.host == 'pair')) {
      params = uri.queryParameters;
    } else if (trimmed.contains('id=') && trimmed.contains('s=')) {
      params = Uri.splitQueryString(trimmed.replaceFirst(RegExp(r'^\?'), ''));
    } else {
      throw const FormatException('這不是機器人的配對 QR code');
    }
    final id = (params['id'] ?? '').trim().toUpperCase();
    final secret = (params['s'] ?? '').trim();
    if (!idPattern.hasMatch(id)) {
      throw const FormatException('配對碼裡沒有有效的機器人 ID');
    }
    if (secret.length < 16 || !RegExp(r'^[A-Za-z2-7=]+$').hasMatch(secret)) {
      throw const FormatException('配對碼裡的密鑰無效');
    }
    final relay = (params['h'] ?? '').trim();
    if (relay.isNotEmpty && !relay.startsWith('ws://') && !relay.startsWith('wss://')) {
      throw const FormatException('relay 位址必須是 ws:// 或 wss://');
    }
    final lan = (params['l'] ?? '').trim();
    return PairedRobot(
      id: id,
      secret: secret.toUpperCase().replaceAll('=', ''),
      name: (params['n'] ?? '').trim(),
      relayUrl: relay,
      lanAddress: lan,
      cameraUrl: (params['c'] ?? '').trim(),
      // a robot without a relay can only be reached over the LAN
      preferLan: relay.isEmpty && lan.isNotEmpty,
      pairedAt: now ?? DateTime.now(),
    );
  }
}
