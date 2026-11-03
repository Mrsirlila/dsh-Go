// dsh-pocket hosts: QR/link parsing, route classification, and PocketHostLink
// picking LAN → Tailscale → public, syncing entry.json and switching routes.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/pocket/pocket_host_config.dart';
import 'package:dsh_app/remote/pocket/pocket_link.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// One HTTP server stands in for every route; [up] decides which answer.
class _FakeRoutes {
  _FakeRoutes(this.server);

  final HttpServer server;
  final up = <PocketRoute>{};
  final pins = <PocketRoute, String>{};
  final calls = <(PocketRoute, String?)>[];
  String entryJson = '{"v":1}';

  static Future<_FakeRoutes> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final routes = _FakeRoutes(server);
    server.listen((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(routes.entryJson);
      await req.response.close();
    });
    return routes;
  }

  PocketRoute _routeOf(Uri base) => classifyPocketUrl(base.toString());

  Future<DshClient> connect(Uri base, {String? pin, required Duration connectTimeout}) async {
    final route = _routeOf(base);
    calls.add((route, pin));
    if (!up.contains(route)) throw const DshTransportException('unreachable');
    final want = pins[route];
    if (want != null && want != pin) throw const DshHttpException(401, 'proxy access PIN missing or rejected');
    // Every route lands on the same local server (entry.json).
    return DshClient(DshConnection(Uri.parse('http://127.0.0.1:${server.port}')));
  }
}

const _config = PocketHostConfig(
  id: 'pocket-1',
  name: '主机',
  lanUrl: 'http://192.168.5.66:3081',
  tailscaleUrl: 'http://100.121.33.31:3081',
  publicUrl: 'https://old.trycloudflare.com',
);

Backoff _quick() =>
    Backoff(initial: const Duration(milliseconds: 10), max: const Duration(milliseconds: 20), maxAttempts: 3);

void main() {
  group('QR codes and addresses', () {
    test('each dsh-pocket code maps to its route, PIN included', () {
      final lan = PocketScan.tryParse('http://192.168.5.66:3081')!;
      expect((lan.route, lan.url, lan.pin), (PocketRoute.lan, 'http://192.168.5.66:3081', null));
      final ts = PocketScan.tryParse('http://100.121.33.31:3081/?token=LANPIN99')!;
      expect((ts.route, ts.pin), (PocketRoute.tailscale, 'LANPIN99'));
      final pub = PocketScan.tryParse('https://flashers-ultra.trycloudflare.com/?token=PUB12345')!;
      expect((pub.route, pub.url, pub.pin), (PocketRoute.public, 'https://flashers-ultra.trycloudflare.com', 'PUB12345'));
      expect(PocketScan.tryParse('192.168.1.5:3081')!.url, 'http://192.168.1.5:3081');
      expect(PocketScan.tryParse('not a url'), isNull);
      expect(PocketScan.tryParse('ftp://x'), isNull);
    });

    test('ranges follow the plugin', () {
      expect(classifyPocketUrl('http://10.0.0.2:3081'), PocketRoute.lan);
      expect(classifyPocketUrl('http://172.20.1.1:3081'), PocketRoute.lan);
      expect(classifyPocketUrl('http://pc.local:3081'), PocketRoute.lan);
      expect(classifyPocketUrl('http://100.64.0.1:3081'), PocketRoute.tailscale);
      expect(classifyPocketUrl('http://100.128.0.1:3081'), PocketRoute.public);
      expect(classifyPocketUrl('http://pc.tail1234.ts.net:3081'), PocketRoute.tailscale);
      expect(classifyPocketUrl('https://a.trycloudflare.com'), PocketRoute.public);
    });

    test('entry.json updates addresses and keeps ones the computer no longer reports', () {
      final info = PocketEntryInfo.fromJson({
        'v': 1,
        'lanUrl': 'http://192.168.5.70:3081',
        'tailscaleUrl': null,
        'publicUrl': 'https://new.trycloudflare.com/',
        'publicPin': 'NEWPIN12',
      })!;
      final next = info.applyTo(_config);
      expect(next.lanUrl, 'http://192.168.5.70:3081');
      expect(next.tailscaleUrl, _config.tailscaleUrl);
      expect(next.publicUrl, 'https://new.trycloudflare.com');
      expect(info.publicPin, 'NEWPIN12');
    });

    test('config survives JSON; a pinned mode narrows the candidates', () {
      final pinned = _config.copyWith(mode: PocketRouteMode.public);
      expect(PocketHostConfig.fromJson(pinned.toJson()), pinned);
      expect(pinned.candidates, [PocketRoute.public]);
      expect(_config.candidates, PocketRoute.values);
      expect(_config.copyWith(tailscaleUrl: () => null).candidates, [PocketRoute.lan, PocketRoute.public]);
    });
  });

  group('PocketHostLink', () {
    late _FakeRoutes routes;
    final links = <PocketHostLink>[];

    setUp(() async => routes = await _FakeRoutes.start());
    tearDown(() async {
      for (final l in links) {
        await l.close();
      }
      links.clear();
      await routes.server.close(force: true);
    });

    PocketHostLink link({
      PocketHostConfig Function()? read,
      PocketSecrets secrets = const PocketSecrets(publicPin: 'PUB12345'),
      Future<void> Function(PocketEntryInfo)? onEntry,
      Stream<void>? kicks,
      bool retryFirstOpen = true,
    }) {
      final l = PocketHostLink(
        readConfig: read ?? () => _config,
        loadSecrets: () async => secrets,
        onEntryInfo: onEntry,
        connector: routes.connect,
        kicks: kicks,
        backoff: _quick(),
        retryFirstOpen: retryFirstOpen,
      );
      links.add(l);
      return l;
    }

    test('uses the first route that answers, with that route\'s PIN', () async {
      routes.up.addAll([PocketRoute.public]);
      routes.pins[PocketRoute.public] = 'PUB12345';
      final l = link();
      await l.open();
      expect(l.route, PocketRoute.public);
      expect(routes.calls.map((c) => c.$1), [PocketRoute.lan, PocketRoute.tailscale, PocketRoute.public]);
      expect(routes.calls.last.$2, 'PUB12345');
      expect(routes.calls.first.$2, isNull);
      expect(l.status.isConnected, isTrue);
    });

    test('a wrong PIN on the only route that answers fails without retrying', () async {
      routes.up.add(PocketRoute.public);
      routes.pins[PocketRoute.public] = 'RIGHTPIN';
      final l = link(read: () => _config.copyWith(mode: PocketRouteMode.public));
      await expectLater(l.open(), throwsA(isA<HostLinkError>().having((e) => e.kind, 'kind', HostLinkErrorKind.authFailed)));
      expect(l.status.phase, HostLinkPhase.failed);
    });

    test('nothing answering is retryable, and reported after the attempts run out', () async {
      final l = link();
      await expectLater(l.open(), throwsA(isA<HostLinkError>().having((e) => e.retryable, 'retryable', isTrue)));
    });

    test('a live route hands the computer\'s addresses and public PIN over', () async {
      routes.up.add(PocketRoute.lan);
      routes.entryJson =
          '{"v":1,"lanUrl":"http://192.168.5.66:3081","publicUrl":"https://fresh.trycloudflare.com","publicPin":"FRESHPIN"}';
      final got = Completer<PocketEntryInfo>();
      final l = link(onEntry: (info) async => got.isCompleted ? null : got.complete(info));
      await l.open();
      final info = await got.future.timeout(const Duration(seconds: 5));
      expect(info.publicUrl, 'https://fresh.trycloudflare.com');
      expect(info.publicPin, 'FRESHPIN');
    });

    test('a network change moves to a better route when it answers', () async {
      routes.up.add(PocketRoute.public);
      final kicks = StreamController<void>.broadcast();
      addTearDown(kicks.close);
      final l = link(kicks: kicks.stream);
      final first = await l.open();
      expect(l.route, PocketRoute.public);

      // Back home: the LAN answers again.
      routes.up.add(PocketRoute.lan);
      final replaced = l.clients.first;
      kicks.add(null);
      final next = await replaced.timeout(const Duration(seconds: 5));
      expect(next, isNot(same(first)));
      expect(l.route, PocketRoute.lan);
      expect(l.status.isConnected, isTrue);
    });

    test('a network change with no better route keeps the current one', () async {
      routes.up.add(PocketRoute.public);
      final kicks = StreamController<void>.broadcast();
      addTearDown(kicks.close);
      final l = link(kicks: kicks.stream);
      final first = await l.open();
      final seen = <HostLinkPhase>[];
      final sub = l.statuses.listen((s) => seen.add(s.phase));
      addTearDown(sub.cancel);
      kicks.add(null);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(l.route, PocketRoute.public);
      expect(l.currentClient, same(first));
      expect(seen, isNot(contains(HostLinkPhase.connecting)));
    });
  });
}
