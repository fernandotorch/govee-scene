import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

abstract class SpotifyService {
  static SpotifyService? _instance;
  factory SpotifyService.create() =>
      _instance ??= (Platform.isAndroid ? AndroidSpotifyService() : DesktopSpotifyService());

  /// null = unknown / not applicable, true = logged in, false = needs login.
  ValueNotifier<bool?> get connected;
  /// true while a browser login is waiting for approval.
  ValueNotifier<bool> get loggingIn;
  /// Starts the browser login. Returns true if tokens were saved.
  Future<bool> login();
  Future<void> cancelLogin();

  Future<void> connect();
  Future<void> refresh();
  Future<void> disconnect();
  Future<void> play(String uri, int startTimeSeconds);
  Future<void> pause();
  Future<void> resume();
  Future<void> skip();
  Future<void> seekRelative(int deltaMs);

  /// Called when the first trigger starts ducking (0 -> 1 active ducks).
  Future<void> duckStart();

  /// Called when the last trigger releases the duck (1 -> 0 active ducks).
  Future<void> duckEnd();
}

class AndroidSpotifyService implements SpotifyService {
  static const _channel = MethodChannel('com.feru.govee_scene/wifi');

  @override
  final ValueNotifier<bool?> connected = ValueNotifier<bool?>(null);

  @override
  final ValueNotifier<bool> loggingIn = ValueNotifier<bool>(false);

  @override
  Future<bool> login() async => false;

  @override
  Future<void> cancelLogin() async {}

  @override
  Future<void> connect() async {
    await _channel.invokeMethod('spotifyConnect').catchError((_) {});
  }

  @override
  Future<void> refresh() async {
    await _channel.invokeMethod('spotifyRefresh').catchError((_) {});
  }

  @override
  Future<void> disconnect() async {
    await _channel.invokeMethod('spotifyDisconnect').catchError((_) {});
  }

  @override
  Future<void> play(String uri, int startTimeSeconds) async {
    await _channel.invokeMethod('spotifyPlay', {
      'uri': uri,
      'startTime': startTimeSeconds,
    }).catchError((_) {});
  }

  @override
  Future<void> pause() async {
    await _channel.invokeMethod('spotifyPause', null).catchError((_) {});
  }

  @override
  Future<void> resume() async {
    await _channel.invokeMethod('spotifyResume', null).catchError((_) {});
  }

  @override
  Future<void> skip() async {
    await _channel.invokeMethod('spotifySkip').catchError((_) {});
  }

  @override
  Future<void> seekRelative(int deltaMs) async {
    await _channel.invokeMethod('spotifySeekRelative', deltaMs).catchError((_) {});
  }

  @override
  Future<void> duckStart() async {}

  @override
  Future<void> duckEnd() async {}
}

class _ApiResponse {
  final int statusCode;
  final String body;
  _ApiResponse(this.statusCode, this.body);
}

class DesktopSpotifyService implements SpotifyService {
  static const String _clientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const String _redirectUri = 'http://127.0.0.1:8898/callback';
  static const double _spotifyDuckFactor = 0.3;

  static bool _warnedNoClientId = false;
  static bool _isAuthenticating = false;

  HttpServer? _authServer;
  int _loginGeneration = 0;
  String? _deviceId;

  @override
  final ValueNotifier<bool?> connected = ValueNotifier<bool?>(null);

  @override
  final ValueNotifier<bool> loggingIn = ValueNotifier<bool>(false);

  @override
  Future<void> cancelLogin() async {
    if (_authServer != null) {
      debugPrint('SpotifyService: login cancelled');
      await _authServer!.close(force: true);
    }
  }

  @override
  Future<bool> login() async {
    if (_isAuthenticating || loggingIn.value) {
      await cancelLogin();
      final stopwatch = Stopwatch()..start();
      while (_isAuthenticating && stopwatch.elapsedMilliseconds < 2000) {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    final gen = ++_loginGeneration;
    loggingIn.value = true;
    try {
      final success = await _startAuth();
      if (success) {
        connected.value = true;
      }
      return success;
    } finally {
      if (_loginGeneration == gen) {
        loggingIn.value = false;
      }
    }
  }

  int? _preDuckVolume;

  bool _checkClientId() {
    if (_clientId.isEmpty) {
      if (!_warnedNoClientId) {
        _warnedNoClientId = true;
        debugPrint('SpotifyService: SPOTIFY_CLIENT_ID is not configured. Spotify desktop operations are disabled.');
      }
      return false;
    }
    return true;
  }

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = Uint8List(96);
    for (int i = 0; i < 96; i++) {
      bytes[i] = random.nextInt(256);
    }
    final encoded = base64Url.encode(bytes).replaceAll('=', '');
    return encoded.length > 128 ? encoded.substring(0, 128) : encoded;
  }

  String _generateCodeChallenge(String verifier) {
    final digest = sha256.convert(ascii.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }

  Future<File> _getTokenFile() async {
    final supportDir = await getApplicationSupportDirectory();
    return File('${supportDir.path}/spotify_tokens.json');
  }

  Future<Map<String, dynamic>?> _readTokens() async {
    try {
      final file = await _getTokenFile();
      if (!await file.exists()) return null;
      final content = await file.readAsString();
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeTokens({
    required String accessToken,
    String? refreshToken,
    required int expiresAt,
  }) async {
    try {
      final file = await _getTokenFile();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final data = <String, dynamic>{
        'access_token': accessToken,
        if (refreshToken != null && refreshToken.isNotEmpty)
          'refresh_token': refreshToken,
        'expires_at': expiresAt,
      };
      await file.writeAsString(jsonEncode(data));
      connected.value = true;
    } catch (_) {}
  }

  Future<bool> _startAuth() async {
    if (!_checkClientId()) return false;
    if (_isAuthenticating) return false;
    _isAuthenticating = true;

    HttpServer? server;
    Timer? timeoutTimer;
    bool authSuccess = false;

    try {
      final verifier = _generateCodeVerifier();
      final challenge = _generateCodeChallenge(verifier);

      try {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8898);
        _authServer = server;
      } on SocketException catch (e) {
        debugPrint(
            'SpotifyService: cannot listen on 127.0.0.1:8898 (port in use?) — Spotify login aborted: $e');
        return false;
      }

      timeoutTimer = Timer(const Duration(minutes: 2), () {
        debugPrint('SpotifyService: login timed out after 2 minutes');
        try {
          server?.close(force: true);
        } catch (_) {}
      });

      final authUri = Uri.https('accounts.spotify.com', '/authorize', {
        'client_id': _clientId,
        'response_type': 'code',
        'redirect_uri': _redirectUri,
        'code_challenge_method': 'S256',
        'code_challenge': challenge,
        'scope': 'user-modify-playback-state user-read-playback-state',
      });

      debugPrint('SpotifyService: opening Spotify login in browser: $authUri');

      try {
        await Process.run('xdg-open', [authUri.toString()]);
      } catch (e) {
        debugPrint('SpotifyService: failed to launch browser: $e');
      }

      await for (final request in server) {
        if (request.uri.path == '/callback') {
          final error = request.uri.queryParameters['error'];
          final code = request.uri.queryParameters['code'];
          final bool success;

          if (error != null && error.isNotEmpty) {
            debugPrint('SpotifyService: Spotify login failed: $error');
            success = false;
          } else if (code == null || code.isEmpty) {
            debugPrint('SpotifyService: Spotify login failed: code is missing');
            success = false;
          } else {
            success = await _exchangeCode(code, verifier);
          }

          authSuccess = success;

          request.response.headers.contentType = ContentType.html;
          if (success) {
            request.response.write(
              '<!DOCTYPE html><html><body><h3>Spotify connected &mdash; you can close this tab</h3></body></html>',
            );
          } else {
            final errorDetail =
                (error != null && error.isNotEmpty) ? '<p>Error: $error</p>' : '';
            request.response.write(
              '<!DOCTYPE html><html><body><h3>Spotify login failed &mdash; check the app log</h3>$errorDetail</body></html>',
            );
          }
          await request.response.close();
          break;
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      }
    } catch (e) {
      debugPrint('SpotifyService: auth flow failed: $e');
    } finally {
      timeoutTimer?.cancel();
      try {
        await server?.close(force: true);
      } catch (_) {}
      _authServer = null;
      _isAuthenticating = false;
    }
    return authSuccess;
  }

  Future<bool> _exchangeCode(String code, String verifier) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .postUrl(Uri.parse('https://accounts.spotify.com/api/token'))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      final body = 'grant_type=authorization_code'
          '&code=${Uri.encodeQueryComponent(code)}'
          '&redirect_uri=${Uri.encodeQueryComponent(_redirectUri)}'
          '&client_id=${Uri.encodeQueryComponent(_clientId)}'
          '&code_verifier=${Uri.encodeQueryComponent(verifier)}';
      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final respBody =
            await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        final newAccess = json['access_token'] as String;
        final newRefresh = json['refresh_token'] as String?;
        final expiresIn = json['expires_in'] as num;
        final expiresAt =
            DateTime.now().millisecondsSinceEpoch + (expiresIn.toInt() * 1000);
        await _writeTokens(
          accessToken: newAccess,
          refreshToken: newRefresh,
          expiresAt: expiresAt,
        );
        debugPrint('SpotifyService: login saved');
        return true;
      } else {
        final respBody =
            await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
        debugPrint(
            'SpotifyService: token exchange failed (${response.statusCode}): $respBody');
        return false;
      }
    } catch (e) {
      debugPrint('SpotifyService: token exchange failed: $e');
      return false;
    } finally {
      client?.close();
    }
  }

  Future<String?> _refreshToken() async {
    if (!_checkClientId()) return null;
    final tokens = await _readTokens();
    final refreshToken = tokens?['refresh_token'] as String?;
    if (refreshToken == null || refreshToken.isEmpty) return null;

    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final request = await client
          .postUrl(Uri.parse('https://accounts.spotify.com/api/token'))
          .timeout(const Duration(seconds: 10));
      request.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      final body = 'grant_type=refresh_token'
          '&refresh_token=${Uri.encodeQueryComponent(refreshToken)}'
          '&client_id=${Uri.encodeQueryComponent(_clientId)}';
      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 10));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final respBody =
            await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
        final json = jsonDecode(respBody) as Map<String, dynamic>;
        final newAccess = json['access_token'] as String;
        final newRefreshRaw = json['refresh_token'] as String?;
        final newRefresh = (newRefreshRaw != null && newRefreshRaw.isNotEmpty)
            ? newRefreshRaw
            : refreshToken;
        final expiresIn = json['expires_in'] as num;
        final expiresAt =
            DateTime.now().millisecondsSinceEpoch + (expiresIn.toInt() * 1000);
        await _writeTokens(
          accessToken: newAccess,
          refreshToken: newRefresh,
          expiresAt: expiresAt,
        );
        return newAccess;
      } else if (response.statusCode == 400 || response.statusCode == 401) {
        await response.drain();
        try {
          final file = await _getTokenFile();
          if (await file.exists()) {
            await file.delete();
          }
        } catch (_) {}
        connected.value = false;
        debugPrint('SpotifyService: saved login is no longer valid — reconnect');
        return null;
      }
      await response.drain();
    } catch (_) {
    } finally {
      client?.close();
    }
    return null;
  }

  Future<String?> _validToken() async {
    if (!_checkClientId()) return null;
    final tokens = await _readTokens();
    final token = tokens?['access_token'] as String?;
    if (token == null || token.isEmpty) return null;
    final expiresAt = (tokens?['expires_at'] as num?)?.toInt() ?? 0;
    if (DateTime.now().millisecondsSinceEpoch > expiresAt - 60000) {
      return _refreshToken();
    }
    return token;
  }

  Future<_ApiResponse?> _sendRequest(
    String method,
    String url,
    String token, {
    String? jsonBody,
  }) async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      final uri = Uri.parse(url);
      final HttpClientRequest request;
      switch (method.toUpperCase()) {
        case 'PUT':
          request = await client.putUrl(uri).timeout(const Duration(seconds: 10));
          break;
        case 'POST':
          request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
          break;
        case 'GET':
          request = await client.getUrl(uri).timeout(const Duration(seconds: 10));
          break;
        default:
          return null;
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (jsonBody != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonBody);
      } else if (method.toUpperCase() == 'PUT' || method.toUpperCase() == 'POST') {
        request.headers.set(HttpHeaders.contentLengthHeader, '0');
      }
      final response = await request.close().timeout(const Duration(seconds: 10));
      final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        debugPrint('SpotifyService: $method ${uri.path} ${response.statusCode}: $body');
      }
      return _ApiResponse(response.statusCode, body);
    } catch (_) {
      return null;
    } finally {
      client?.close();
    }
  }

  String _toSpotifyUri(String input) {
    if (input.startsWith('spotify:')) return input;
    final match = RegExp(r'open\.spotify\.com/([^/?]+)/([^?]+)').firstMatch(input);
    if (match != null) {
      return 'spotify:${match.group(1)}:${match.group(2)}';
    }
    return input;
  }

  @override
  Future<void> connect() async {
    if (!_checkClientId()) {
      connected.value = false;
      return;
    }
    final tokens = await _readTokens();
    final refreshToken = tokens?['refresh_token'] as String?;
    connected.value = refreshToken != null && refreshToken.isNotEmpty;
  }

  @override
  Future<void> refresh() async {
    if (!_checkClientId()) return;
    await _refreshToken();
  }

  @override
  Future<void> disconnect() async {}

  Future<String?> _pickDevice(String token) async {
    final res = await _sendRequest(
      'GET',
      'https://api.spotify.com/v1/me/player/devices',
      token,
    );
    if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final rawDevices = json['devices'] as List<dynamic>? ?? [];
        final devices = rawDevices
            .whereType<Map<String, dynamic>>()
            .where((d) =>
                d['is_restricted'] != true &&
                d['id'] is String &&
                (d['id'] as String).isNotEmpty)
            .toList();

        if (devices.isNotEmpty) {
          Map<String, dynamic>? chosen;
          if (_deviceId != null && _deviceId!.isNotEmpty) {
            for (final d in devices) {
              if (d['id'] == _deviceId) {
                chosen = d;
                break;
              }
            }
          }
          if (chosen == null) {
            for (final d in devices) {
              if (d['is_active'] == true) {
                chosen = d;
                break;
              }
            }
          }
          if (chosen == null) {
            for (final d in devices) {
              if (d['type'] == 'Computer') {
                chosen = d;
                break;
              }
            }
          }
          chosen ??= devices.first;

          final id = chosen['id'] as String;
          _deviceId = id;
          final name = chosen['name'] ?? '';
          final type = chosen['type'] ?? '';
          debugPrint('SpotifyService: using device "$name" ($type)');
          return id;
        }
      } catch (_) {}
    }
    debugPrint(
        'SpotifyService: no Spotify player is open — open Spotify (web player or desktop app) on this PC');
    return null;
  }

  Future<_ApiResponse?> _sendPlayRequest(
    String token, {
    String? jsonBody,
  }) async {
    var res = await _sendRequest(
      'PUT',
      'https://api.spotify.com/v1/me/player/play',
      token,
      jsonBody: jsonBody,
    );
    if (res != null &&
        res.statusCode == 404 &&
        res.body.contains('NO_ACTIVE_DEVICE')) {
      final deviceId = await _pickDevice(token);
      if (deviceId != null) {
        res = await _sendRequest(
          'PUT',
          'https://api.spotify.com/v1/me/player/play?device_id=${Uri.encodeQueryComponent(deviceId)}',
          token,
          jsonBody: jsonBody,
        );
      }
    }
    return res;
  }

  @override
  Future<void> play(String uri, int startTimeSeconds) async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) {
      debugPrint('SpotifyService: not connected — press "Connect Spotify" in the menu');
      return;
    }
    final spotifyUri = _toSpotifyUri(uri);
    final isTrack = spotifyUri.contains(':track:');
    final body = isTrack
        ? jsonEncode({'uris': [spotifyUri]})
        : jsonEncode({'context_uri': spotifyUri});

    final res = await _sendPlayRequest(
      token,
      jsonBody: body,
    );
    if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
      debugPrint('SpotifyService: play $uri ok');
      if (startTimeSeconds > 0) {
        await Future.delayed(const Duration(milliseconds: 800));
        await _sendRequest(
          'PUT',
          'https://api.spotify.com/v1/me/player/seek?position_ms=${startTimeSeconds * 1000}',
          token,
        );
      }
    }
  }

  @override
  Future<void> pause() async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) return;
    await _sendRequest('PUT', 'https://api.spotify.com/v1/me/player/pause', token);
  }

  @override
  Future<void> resume() async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) return;
    await _sendPlayRequest(token);
  }

  @override
  Future<void> skip() async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) return;
    await _sendRequest('POST', 'https://api.spotify.com/v1/me/player/next', token);
  }

  @override
  Future<void> seekRelative(int deltaMs) async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) return;
    final res = await _sendRequest('GET', 'https://api.spotify.com/v1/me/player', token);
    if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final progress = json['progress_ms'] as int?;
        if (progress != null && progress >= 0) {
          final target = max(0, progress + deltaMs);
          await _sendRequest(
            'PUT',
            'https://api.spotify.com/v1/me/player/seek?position_ms=$target',
            token,
          );
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> duckStart() async {
    if (!_checkClientId()) return;
    final token = await _validToken();
    if (token == null) {
      _preDuckVolume = null;
      return;
    }
    final res = await _sendRequest('GET', 'https://api.spotify.com/v1/me/player', token);
    if (res != null && res.statusCode >= 200 && res.statusCode < 300) {
      try {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final device = json['device'] as Map<String, dynamic>?;
        final vol = device?['volume_percent'] as int?;
        if (vol != null) {
          _preDuckVolume = vol;
          final ducked = (_preDuckVolume! * _spotifyDuckFactor).round().clamp(0, 100);
          await _sendRequest(
            'PUT',
            'https://api.spotify.com/v1/me/player/volume?volume_percent=$ducked',
            token,
          );
          return;
        }
      } catch (_) {}
    }
    _preDuckVolume = null;
  }

  @override
  Future<void> duckEnd() async {
    if (!_checkClientId()) return;
    final vol = _preDuckVolume;
    _preDuckVolume = null;
    if (vol != null) {
      final token = await _validToken();
      if (token == null) return;
      await _sendRequest(
        'PUT',
        'https://api.spotify.com/v1/me/player/volume?volume_percent=$vol',
        token,
      );
    }
  }
}
