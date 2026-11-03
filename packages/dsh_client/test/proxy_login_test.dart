// DshConnection.loginViaProxy against a server that answers like the
// dsh-pocket proxy (port 3081): it checks `?token=<PIN>`, does the launch-token
// handshake upstream and returns a 200 page carrying both cookies.

import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

const _pin = 'PIN12345';
const _session = 'dsh-auth-abc';
const _pocket = 'dsh_pocket_token';

Future<HttpServer> _fakePocket({required bool protected, List<String?>? cookiesSeen}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    final res = req.response;
    final cookie = req.headers.value(HttpHeaders.cookieHeader);
    cookiesSeen?.add(cookie);
    final authed = cookie != null && cookie.contains('$_pocket=hash') && cookie.contains('$_session=v1.ok');
    if (req.uri.path == '/') {
      final pinOk = !protected || req.uri.queryParameters['token'] == _pin;
      res.headers.contentType = ContentType.html;
      if (!pinOk) {
        res.write('<form>login</form>'); // the proxy's login page: 200, no cookie
      } else {
        res.headers.add('set-cookie', '$_session=v1.ok; Max-Age=2592000; Path=/; HttpOnly; SameSite=Strict');
        if (protected) res.headers.add('set-cookie', '$_pocket=hash; HttpOnly; SameSite=Lax; Path=/; Max-Age=2592000');
        res.write('<meta http-equiv="refresh" content="0; url=/">');
      }
    } else if (req.uri.path == '/dsh-pocket/entry.json') {
      res.statusCode = authed || !protected ? 200 : 401;
      res.write('{"v":1,"publicPin":"x"}');
    }
    await res.close();
  });
  return server;
}

void main() {
  test('a right PIN yields the session cookie and keeps the proxy cookie as a companion', () async {
    final seen = <String?>[];
    final server = await _fakePocket(protected: true, cookiesSeen: seen);
    addTearDown(() => server.close(force: true));
    final connection = DshConnection(Uri.parse('http://127.0.0.1:${server.port}'));
    final cookie = await connection.loginViaProxy(pin: _pin);
    expect(cookie.name, _session);
    expect(cookie.companions, {_pocket: 'hash'});
    expect(cookie.header, '$_session=v1.ok; $_pocket=hash');
    final entry = await connection.get('/dsh-pocket/entry.json');
    expect(entry.statusCode, 200);
    expect(seen.last, '$_session=v1.ok; $_pocket=hash');
  });

  test('a wrong or missing PIN is a 401', () async {
    final server = await _fakePocket(protected: true);
    addTearDown(() => server.close(force: true));
    final base = Uri.parse('http://127.0.0.1:${server.port}');
    for (final pin in ['nope', null]) {
      await expectLater(
        DshConnection(base).loginViaProxy(pin: pin),
        throwsA(isA<DshHttpException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    }
  });

  test('an unprotected entry signs in without a PIN', () async {
    final server = await _fakePocket(protected: false);
    addTearDown(() => server.close(force: true));
    final cookie = await DshConnection(Uri.parse('http://127.0.0.1:${server.port}')).loginViaProxy();
    expect(cookie.name, _session);
    expect(cookie.companions, isEmpty);
  });

  test('companions survive JSON and stay out of a plain cookie', () {
    const plain = DshCookie(name: 'dsh-auth-x', value: 'v', authority: 'h:1');
    expect(plain.header, 'dsh-auth-x=v');
    expect(plain.toJson().containsKey('companions'), isFalse);
    const withProxy = DshCookie(name: 'dsh-auth-x', value: 'v', authority: 'h:1', companions: {_pocket: 'p'});
    final back = DshCookie.fromJson(withProxy.toJson());
    expect(back.header, 'dsh-auth-x=v; $_pocket=p');
  });
}
