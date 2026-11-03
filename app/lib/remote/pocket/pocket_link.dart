import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../../l10n/l10n.dart';
import '../link_status.dart';
import 'pocket_host_config.dart';

/// Signs in to `dsh web` through one dsh-pocket proxy address. Tests swap it.
typedef PocketClientConnector = Future<DshClient> Function(Uri baseUri, {String? pin, required Duration connectTimeout});

Future<DshClient> defaultPocketConnector(Uri baseUri, {String? pin, required Duration connectTimeout}) async {
  final connection = DshConnection(baseUri, connectTimeout: connectTimeout);
  final client = DshClient(connection);
  try {
    await connection.loginViaProxy(pin: pin).timeout(connectTimeout + const Duration(seconds: 5));
    await client.mux.ready(timeout: const Duration(seconds: 20));
    return client;
  } on Object {
    await client.close().catchError((_) {});
    rethrow;
  }
}

/// Reads `/dsh-pocket/entry.json` over a signed-in client.
Future<PocketEntryInfo?> fetchPocketEntry(DshClient client, {Duration timeout = const Duration(seconds: 8)}) async {
  final response = await client.connection.get('/dsh-pocket/entry.json', timeout: timeout);
  if (response.statusCode == 404) return null; // plugin older than the entry route
  if (response.statusCode != 200) throw DshHttpException(response.statusCode, 'entry.json');
  return PocketEntryInfo.fromJson(jsonDecode(response.text));
}

String pocketRouteLabel(PocketRoute route) => switch (route) {
  PocketRoute.lan => appL10n.pocketRouteLan,
  PocketRoute.tailscale => appL10n.pocketRouteTailscale,
  PocketRoute.public => appL10n.pocketRoutePublic,
};

/// A computer running the dsh-pocket plugin, reached over plain HTTP(S) on
/// its proxy port: LAN, Tailscale or the Cloudflare tunnel.
///
/// The proxy rewrites Host/Origin to loopback and injects `dsh web`'s launch
/// token, so the app signs in with only the access PIN (when that entry is
/// protected) and then talks to the engine exactly as it does locally.
///
/// While connected the link reads `/dsh-pocket/entry.json` every
/// [syncInterval] and hands the computer's current addresses and public PIN
/// to [onEntryInfo]: being on the LAN keeps the public route ready for when
/// the phone leaves. On a network change (and when the socket drops) it
/// probes the routes again in order and, in auto mode, moves to the first
/// that answers, publishing the new client on [clients].
class PocketHostLink implements HostLink {
  PocketHostLink({
    required this._readConfig,
    required this._loadSecrets,
    this.onEntryInfo,
    PocketClientConnector? connector,
    Stream<void>? kicks,
    Backoff? backoff,
    this.syncInterval = const Duration(seconds: 60),
    this.retryFirstOpen = true,
  }) : _connector = connector ?? defaultPocketConnector,
       _backoff = backoff ?? Backoff(maxAttempts: null, max: const Duration(seconds: 20)) {
    _kickSub = kicks?.listen((_) => kick());
  }

  final PocketHostConfig Function() _readConfig;
  final Future<PocketSecrets> Function() _loadSecrets;
  final Future<void> Function(PocketEntryInfo info)? onEntryInfo;
  final PocketClientConnector _connector;
  final Backoff _backoff;
  final Duration syncInterval;

  /// False for "测试连接": report the first failure instead of retrying.
  final bool retryFirstOpen;

  final _statuses = StreamController<HostLinkStatus>.broadcast(sync: true);
  final _clients = StreamController<DshClient>.broadcast();
  final _delay = InterruptibleDelay();
  StreamSubscription<void>? _kickSub;
  StreamSubscription<DshConnectionState>? _muxSub;
  Timer? _syncTimer;
  Timer? _stallTimer;
  HostLinkStatus _status = HostLinkStatus.idle;
  DshClient? _client;
  PocketRoute? _route;
  Future<DshClient>? _opening;
  bool _closed = false;
  bool _recovering = false;
  bool _switching = false;

  /// The route the current client uses.
  PocketRoute? get route => _route;

  /// Base URL of the current route (for the DSH Web page).
  String? get currentUrl => _route == null ? null : _readConfig().urlOf(_route!);

  @override
  HostLinkStatus get status => _status;

  @override
  DshClient? get currentClient => _status.isConnected ? _client : null;

  @override
  Stream<HostLinkStatus> get statuses => _statuses.stream;

  @override
  Stream<DshClient> get clients => _clients.stream;

  void _emit(HostLinkStatus next) {
    if (_closed && next.phase != HostLinkPhase.idle) return;
    _status = next;
    _statuses.add(next);
  }

  @override
  Future<DshClient> open() {
    if (_closed) return Future.error(StateError('link closed'));
    final client = _client;
    if (client != null && _status.isConnected) return Future.value(client);
    return _opening ??= _openFirst().whenComplete(() => _opening = null);
  }

  Future<DshClient> _openFirst() async {
    _backoff.reset();
    _emit(const HostLinkStatus(HostLinkPhase.connecting, step: HostLinkStep.connect));
    try {
      return await _connectOnce();
    } on HostLinkError catch (e) {
      if (!e.retryable || !retryFirstOpen) {
        _fail(e);
        rethrow;
      }
      return _recover(e);
    }
  }

  void _fail(HostLinkError error) {
    _stopTimers();
    _emit(HostLinkStatus(HostLinkPhase.failed, step: _status.step, completed: _status.completed, error: error));
  }

  Duration _timeoutFor(PocketRoute route) =>
      route == PocketRoute.public ? const Duration(seconds: 10) : const Duration(seconds: 4);

  /// Tries the routes in order; the first that signs in wins.
  Future<DshClient> _connectOnce({List<PocketRoute>? only, bool quiet = false}) async {
    final config = _readConfig();
    final routes = only ?? config.candidates;
    if (routes.isEmpty) {
      throw HostLinkError(HostLinkErrorKind.other, appL10n.pocketErrNoAddress);
    }
    final secrets = await _loadSecrets();
    if (_closed) throw StateError('link closed');
    HostLinkError? pinError;
    final failures = <String>[];
    for (final route in routes) {
      final url = config.urlOf(route);
      if (url == null) continue;
      final label = pocketRouteLabel(route);
      if (!quiet) _emitStep(HostLinkStep.connect, '$label · ${Uri.parse(url).authority}');
      try {
        final client = await _connector(Uri.parse(url), pin: secrets.pinFor(route), connectTimeout: _timeoutFor(route));
        if (_closed) {
          await client.close().catchError((_) {});
          throw StateError('link closed');
        }
        _install(client, route);
        return client;
      } on DshHttpException catch (e) {
        if (e.statusCode == 401 || e.statusCode == 403) {
          pinError ??= HostLinkError(
            HostLinkErrorKind.authFailed,
            route == PocketRoute.public ? appL10n.pocketErrPublicPin : appL10n.pocketErrLanPin,
            detail: '$label: $e',
          );
        }
        failures.add('$label: $e');
      } on StateError {
        rethrow;
      } catch (e) {
        failures.add('$label: $e');
      }
    }
    // A wrong PIN is something the person has to fix; retrying won't help.
    // Still retry it when another route was merely unreachable (the public
    // PIN may be refreshed over the LAN later).
    if (pinError != null && failures.length == 1) throw pinError;
    throw HostLinkError(
      HostLinkErrorKind.unreachable,
      appL10n.pocketErrUnreachable,
      detail: failures.join('\n'),
      retryable: true,
    );
  }

  void _emitStep(HostLinkStep step, String detail) {
    _emit(
      HostLinkStatus(
        _status.phase == HostLinkPhase.reconnecting ? HostLinkPhase.reconnecting : HostLinkPhase.connecting,
        step: step,
        attempt: _status.attempt,
        detail: detail,
      ),
    );
  }

  void _install(DshClient client, PocketRoute route) {
    final previous = _client;
    _client = client;
    _route = route;
    _watchMux(client);
    _emit(
      HostLinkStatus(
        HostLinkPhase.connected,
        completed: const {HostLinkStep.connect, HostLinkStep.login},
        detail: pocketRouteLabel(route),
      ),
    );
    if (previous != null && !identical(previous, client)) {
      _clients.add(client);
      unawaited(previous.close().catchError((_) {}));
    }
    _startSync();
  }

  void _watchMux(DshClient client) {
    unawaited(_muxSub?.cancel());
    _stallTimer?.cancel();
    _muxSub = client.mux.states.listen((state) {
      if (!identical(client, _client)) return;
      switch (state) {
        case DshConnectionState.unauthorized:
          _lost(HostLinkError(HostLinkErrorKind.loginFailed, appL10n.remoteErrDshSignInExpired, retryable: true));
        case DshConnectionState.reconnecting || DshConnectionState.connecting:
          // The mux retries the same address forever; after a short stall
          // look for another route (the phone left the Wi-Fi).
          _stallTimer ??= Timer(const Duration(seconds: 6), () {
            _stallTimer = null;
            if (identical(client, _client) && client.mux.state != DshConnectionState.connected) {
              _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.pocketErrRouteLost, retryable: true));
            }
          });
        case _:
          _stallTimer?.cancel();
          _stallTimer = null;
      }
    });
  }

  void _startSync() {
    _syncTimer?.cancel();
    unawaited(_sync());
    _syncTimer = Timer.periodic(syncInterval, (_) => unawaited(_sync()));
  }

  void _stopTimers() {
    _syncTimer?.cancel();
    _syncTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  /// Pulls the computer's current addresses and public PIN.
  Future<bool> _sync() async {
    final client = _client;
    if (client == null || _closed) return false;
    try {
      final info = await fetchPocketEntry(client);
      if (info != null && !_closed) await onEntryInfo?.call(info);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _lost(HostLinkError reason) {
    if (_closed || _recovering || _status.phase != HostLinkPhase.connected) return;
    _stopTimers();
    unawaited(_recover(reason).then((_) {}, onError: (_) {}));
  }

  /// Reconnect loop with backoff over all routes. The old client stays
  /// until a new one replaces it (its mux may still come back by itself).
  Future<DshClient> _recover(HostLinkError reason) async {
    _recovering = true;
    _backoff.reset();
    var last = reason;
    try {
      var first = true;
      while (!_closed) {
        if (_backoff.exhausted) {
          _fail(last);
          throw last;
        }
        final delay = first ? Duration.zero : _backoff.next();
        first = false;
        _emit(
          HostLinkStatus(
            HostLinkPhase.reconnecting,
            attempt: _backoff.attempt == 0 ? 1 : _backoff.attempt,
            error: last,
            nextRetryAt: DateTime.now().add(delay),
          ),
        );
        if (delay > Duration.zero) await _delay.wait(delay);
        if (_closed) break;
        // The old client's own mux came back meanwhile: keep it.
        final old = _client;
        if (old != null && old.mux.state == DshConnectionState.connected && last.kind == HostLinkErrorKind.unreachable) {
          _install(old, _route!);
          return old;
        }
        try {
          return await _connectOnce();
        } on HostLinkError catch (e) {
          if (_closed) break;
          if (!e.retryable) {
            _fail(e);
            rethrow;
          }
          last = e;
        }
      }
      throw StateError('link closed');
    } finally {
      _recovering = false;
    }
  }

  /// Network changed (Wi-Fi ↔ mobile data) or the app came back: in auto
  /// mode move to a better route when one answers, otherwise check that the
  /// current one still does.
  Future<void> _reevaluate() async {
    if (_closed || _switching || _status.phase != HostLinkPhase.connected) return;
    final current = _route;
    if (current == null) return;
    _switching = true;
    try {
      final config = _readConfig();
      final better = config.candidates.takeWhile((r) => r != current).toList();
      if (better.isNotEmpty) {
        try {
          await _connectOnce(only: better, quiet: true);
          return;
        } on StateError {
          return;
        } on Object {
          // Not reachable from here: stay where we are.
          if (_closed || _status.phase != HostLinkPhase.connected) return;
        }
      }
      if (!await _sync()) {
        _lost(HostLinkError(HostLinkErrorKind.unreachable, appL10n.pocketErrRouteLost, retryable: true));
      }
    } finally {
      _switching = false;
    }
  }

  @override
  void kick() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.connected:
        unawaited(_reevaluate());
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.failed:
        if (_status.error?.retryable ?? false) retry();
      case HostLinkPhase.idle || HostLinkPhase.connecting:
        break;
    }
  }

  @override
  void retry() {
    if (_closed) return;
    switch (_status.phase) {
      case HostLinkPhase.reconnecting:
        _backoff.reset();
        _delay.skip();
      case HostLinkPhase.connected:
        unawaited(_reevaluate());
      case HostLinkPhase.failed || HostLinkPhase.idle:
        unawaited(open().then((_) {}, onError: (_) {}));
      case HostLinkPhase.connecting:
        break;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _emit(HostLinkStatus.idle);
    _closed = true;
    _delay.cancel();
    _stopTimers();
    await _kickSub?.cancel();
    await _muxSub?.cancel();
    final client = _client;
    _client = null;
    if (client != null) await client.close().catchError((_) {});
    await _statuses.close();
    await _clients.close();
  }
}
