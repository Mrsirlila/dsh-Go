import 'dart:math' as math;

/// One of the three ways into a computer running the dsh-pocket plugin: its
/// reverse proxy (port 3081) on the LAN, over Tailscale, or behind the
/// Cloudflare tunnel.
enum PocketRoute { lan, tailscale, public }

/// Which route a pocket host uses: [auto] tries LAN → Tailscale → public and
/// moves between them as the network changes; the others pin one route.
enum PocketRouteMode {
  auto,
  lan,
  tailscale,
  public;

  PocketRoute? get pinned => switch (this) {
    PocketRouteMode.auto => null,
    PocketRouteMode.lan => PocketRoute.lan,
    PocketRouteMode.tailscale => PocketRoute.tailscale,
    PocketRouteMode.public => PocketRoute.public,
  };
}

/// A saved dsh-pocket host. Persisted as JSON in SharedPreferences; the two
/// access PINs live in the SecretStore under [PocketSecrets] keys.
class PocketHostConfig {
  const PocketHostConfig({
    required this.id,
    required this.name,
    this.lanUrl,
    this.tailscaleUrl,
    this.publicUrl,
    this.mode = PocketRouteMode.auto,
  });

  /// Stable id (`pocket-<hex>`); also the secret-store namespace.
  final String id;
  final String name;

  /// Normalized base URLs (`http://192.168.5.66:3081`, no path or query).
  final String? lanUrl;
  final String? tailscaleUrl;

  /// The Cloudflare quick tunnel changes its name on every restart; the link
  /// refreshes this from `/dsh-pocket/entry.json` while any route is up.
  final String? publicUrl;
  final PocketRouteMode mode;

  String? urlOf(PocketRoute route) => switch (route) {
    PocketRoute.lan => lanUrl,
    PocketRoute.tailscale => tailscaleUrl,
    PocketRoute.public => publicUrl,
  };

  /// Routes to try, in order, for the current [mode].
  List<PocketRoute> get candidates {
    final pinned = mode.pinned;
    final order = pinned == null ? PocketRoute.values : [pinned];
    return [for (final r in order) if (urlOf(r) != null) r];
  }

  /// First configured address, for list rows.
  String get address => lanUrl ?? tailscaleUrl ?? publicUrl ?? '';

  bool get hasAnyUrl => lanUrl != null || tailscaleUrl != null || publicUrl != null;

  PocketHostConfig copyWith({
    String? name,
    String? Function()? lanUrl,
    String? Function()? tailscaleUrl,
    String? Function()? publicUrl,
    PocketRouteMode? mode,
  }) => PocketHostConfig(
    id: id,
    name: name ?? this.name,
    lanUrl: lanUrl != null ? lanUrl() : this.lanUrl,
    tailscaleUrl: tailscaleUrl != null ? tailscaleUrl() : this.tailscaleUrl,
    publicUrl: publicUrl != null ? publicUrl() : this.publicUrl,
    mode: mode ?? this.mode,
  );

  PocketHostConfig withUrl(PocketRoute route, String? url) => switch (route) {
    PocketRoute.lan => copyWith(lanUrl: () => url),
    PocketRoute.tailscale => copyWith(tailscaleUrl: () => url),
    PocketRoute.public => copyWith(publicUrl: () => url),
  };

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (lanUrl != null) 'lanUrl': lanUrl,
    if (tailscaleUrl != null) 'tailscaleUrl': tailscaleUrl,
    if (publicUrl != null) 'publicUrl': publicUrl,
    'mode': mode.name,
  };

  static PocketHostConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final name = raw['name'];
    String? url(Object? v) => v is String ? normalizePocketUrl(v) : null;
    return PocketHostConfig(
      id: id,
      name: name is String && name.trim().isNotEmpty ? name : id,
      lanUrl: url(raw['lanUrl']),
      tailscaleUrl: url(raw['tailscaleUrl']),
      publicUrl: url(raw['publicUrl']),
      mode: PocketRouteMode.values.firstWhere((m) => m.name == raw['mode'], orElse: () => PocketRouteMode.auto),
    );
  }

  static String newId([math.Random? random]) {
    final r = random ?? math.Random.secure();
    final hex = List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return 'pocket-$hex';
  }

  @override
  bool operator ==(Object other) =>
      other is PocketHostConfig &&
      other.id == id &&
      other.name == name &&
      other.lanUrl == lanUrl &&
      other.tailscaleUrl == tailscaleUrl &&
      other.publicUrl == publicUrl &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(id, name, lanUrl, tailscaleUrl, publicUrl, mode);
}

/// The access PINs of one pocket host. The LAN one is usually empty (the
/// plugin only asks for it when LAN protection is on); Tailscale counts as
/// LAN for the plugin (100.64/10), so it shares that PIN.
class PocketSecrets {
  const PocketSecrets({this.lanPin, this.publicPin});

  final String? lanPin;
  final String? publicPin;

  String? pinFor(PocketRoute route) => switch (route) {
    PocketRoute.lan || PocketRoute.tailscale => lanPin,
    PocketRoute.public => publicPin,
  };

  static String lanPinKey(String hostId) => 'pocket.$hostId.lanPin';
  static String publicPinKey(String hostId) => 'pocket.$hostId.publicPin';
}

/// `http(s)://host[:port]` with no path, query or fragment; null when [raw]
/// isn't one. A bare `192.168.5.66:3081` gets `http://`.
String? normalizePocketUrl(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (!text.contains('://')) text = 'http://$text';
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) return null;
  // A hostname, IPv4 or IPv6 literal; not arbitrary text read off a QR code.
  if (!RegExp(r'^([a-zA-Z0-9-]+(\.[a-zA-Z0-9-]+)*|[0-9a-fA-F:.]*:[0-9a-fA-F:.]*)$').hasMatch(uri.host)) return null;
  return Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null).toString();
}

/// Which route an address belongs to, by the same ranges the plugin uses:
/// RFC 1918 / link-local / `.local` are LAN, CGNAT 100.64/10 and `*.ts.net`
/// are Tailscale, anything else is the public tunnel.
PocketRoute classifyPocketUrl(String url) {
  final host = (Uri.tryParse(url)?.host ?? '').toLowerCase();
  final v4 = RegExp(r'^(\d+)\.(\d+)\.\d+\.\d+$').firstMatch(host);
  if (v4 != null) {
    final a = int.parse(v4.group(1)!);
    final b = int.parse(v4.group(2)!);
    if (a == 100 && b >= 64 && b <= 127) return PocketRoute.tailscale;
    if (a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254)) {
      return PocketRoute.lan;
    }
    return PocketRoute.public;
  }
  if (host.endsWith('.ts.net')) return PocketRoute.tailscale;
  if (host.endsWith('.local') || (host.isNotEmpty && !host.contains('.'))) return PocketRoute.lan;
  return PocketRoute.public;
}

/// What one dsh-pocket QR code (or a copied entry link) holds:
/// `http://192.168.5.66:3081`, `http://100.x.y.z:3081/?token=<PIN>`,
/// `https://<name>.trycloudflare.com/?token=<PIN>`.
class PocketScan {
  const PocketScan({required this.route, required this.url, this.pin});

  final PocketRoute route;
  final String url;
  final String? pin;

  static PocketScan? tryParse(String text) {
    final raw = text.trim();
    final url = normalizePocketUrl(raw);
    if (url == null) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'http://$raw');
    final token = uri?.queryParameters['token']?.trim();
    return PocketScan(route: classifyPocketUrl(url), url: url, pin: token == null || token.isEmpty ? null : token);
  }
}

/// `GET /dsh-pocket/entry.json`: every address the computer currently has,
/// plus the public PIN, so one live route keeps the other two up to date.
class PocketEntryInfo {
  const PocketEntryInfo({this.lanUrl, this.tailscaleUrl, this.publicUrl, this.publicPin});

  final String? lanUrl;
  final String? tailscaleUrl;
  final String? publicUrl;
  final String? publicPin;

  static PocketEntryInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    String? url(Object? v) => v is String ? normalizePocketUrl(v) : null;
    final pin = raw['publicPin'];
    return PocketEntryInfo(
      lanUrl: url(raw['lanUrl']),
      tailscaleUrl: url(raw['tailscaleUrl']),
      publicUrl: url(raw['publicUrl']),
      publicPin: pin is String && pin.isNotEmpty ? pin : null,
    );
  }

  /// [config] with the addresses the computer reported. A route the
  /// computer no longer has (tunnel stopped) keeps its last address: it may
  /// come back, and a dead address only costs one failed probe.
  PocketHostConfig applyTo(PocketHostConfig config) => config.copyWith(
    lanUrl: lanUrl == null ? null : () => lanUrl,
    tailscaleUrl: tailscaleUrl == null ? null : () => tailscaleUrl,
    publicUrl: publicUrl == null ? null : () => publicUrl,
  );
}
