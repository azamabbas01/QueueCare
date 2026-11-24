import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// HTTP client for the QueueCare FastAPI service.
///
/// Configure with `--dart-define=QUEUECARE_API_URL=https://...`. The client
/// holds no Supabase secret; privileged database access stays in the API.
///
/// Sessions: the access token is kept in memory only (never written to disk).
/// On a 401 the client silently refreshes once; if that fails it signs out and
/// fires [sessionEvents] so the UI can return to the sign-in screen.
class QueueCareApi {
  QueueCareApi._();

  static const String baseUrl = String.fromEnvironment(
    'QUEUECARE_API_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static final http.Client _client = http.Client();

  static String? accessToken;
  static String? _refreshToken;
  static Map<String, dynamic>? profile;

  /// Emits 'expired' when the session can no longer be used.
  static final StreamController<String> _events =
      StreamController<String>.broadcast();
  static Stream<String> get sessionEvents => _events.stream;
  static Future<bool>? _refreshing;

  static bool get isSignedIn => accessToken != null;
  static String get role => (profile?['role'] as String?) ?? 'patient';

  // ───────────── auth ─────────────

  /// Returns the raw login payload. Callers check `mfa` (admins) and
  /// `must_change_password` before treating the user as fully signed in.
  static Future<Map<String, dynamic>> signIn({
    required String email,
    required String password,
  }) async {
    final result = _asMap(
      await _request(
        'POST',
        '/api/v1/auth/login',
        body: {'email': email.trim(), 'password': password},
        authenticated: false,
        retryOn401: false,
      ),
    );
    _storeSession(result);
    return result;
  }

  /// Patients only. There is deliberately no role parameter.
  static Future<Map<String, dynamic>> registerPatient({
    required String fullName,
    required String email,
    required String password,
    required String phone,
    String? nationalId,
    String language = 'en',
    required bool consentPhoto,
  }) async {
    return _asMap(
      await _request(
        'POST',
        '/api/v1/auth/register',
        body: {
          'full_name': fullName.trim(),
          'email': email.trim(),
          'password': password,
          'phone': phone.trim(),
          if (nationalId != null && nationalId.trim().isNotEmpty)
            'national_id': nationalId.trim(),
          'preferred_language': language,
          'accept_terms': true,
          'consent_data_use': true,
          'consent_photo': consentPhoto,
        },
        authenticated: false,
        retryOn401: false,
      ),
    );
  }

  static Future<void> resendSignupConfirmation(String email) async {
    await _request(
      'POST',
      '/api/v1/auth/resend-signup-confirmation',
      body: {'email': email.trim()},
      authenticated: false,
    );
  }

  static Future<void> requestPasswordReset(String email) async {
    await _request(
      'POST',
      '/api/v1/auth/forgot-password',
      body: {'email': email.trim()},
      authenticated: false,
    );
  }

  static Future<Map<String, dynamic>> me() async {
    final result = _asMap(await _request('GET', '/api/v1/auth/me'));
    profile = Map<String, dynamic>.from(result['user'] as Map);
    return result;
  }

  static Future<void> changePassword({
    required String current,
    required String next,
  }) async {
    await _request(
      'POST',
      '/api/v1/auth/change-password',
      body: {'current_password': current, 'new_password': next},
    );
    profile?['must_change_password'] = false;
  }

  static Future<Map<String, dynamic>> mfaEnroll() async =>
      _asMap(await _request('POST', '/api/v1/auth/mfa/enroll', body: {}));

  static Future<Map<String, dynamic>> mfaVerify({
    required String factorId,
    required String code,
  }) async {
    final result = _asMap(
      await _request(
        'POST',
        '/api/v1/auth/mfa/verify',
        body: {'factor_id': factorId, 'code': code},
        retryOn401: false,
      ),
    );
    _storeSession(result);
    return result;
  }

  /// Signs out on the server (best effort) and clears local state.
  static Future<void> signOut({bool notify = false}) async {
    final hadSession = accessToken != null;
    if (hadSession) {
      try {
        await _request(
          'POST',
          '/api/v1/auth/logout',
          body: {},
          retryOn401: false,
        ).timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    _clear();
    if (notify && hadSession) _events.add('expired');
  }

  static void _storeSession(Map<String, dynamic> result) {
    accessToken = result['access_token'] as String?;
    _refreshToken = (result['refresh_token'] as String?) ?? _refreshToken;
    if (result['user'] is Map) {
      profile = Map<String, dynamic>.from(result['user'] as Map);
    }
  }

  static void _clear() {
    accessToken = null;
    _refreshToken = null;
    profile = null;
  }

  static Future<bool> _refresh() {
    return _refreshing ??= () async {
      final token = _refreshToken;
      if (token == null) return false;
      try {
        final response = await _client
            .post(
              _apiUri('/api/v1/auth/refresh'),
              headers: {
                'Accept': 'application/json',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({'refresh_token': token}),
            )
            .timeout(const Duration(seconds: 15));
        if (response.statusCode != 200) return false;
        _storeSession(
          Map<String, dynamic>.from(jsonDecode(response.body) as Map),
        );
        return true;
      } catch (_) {
        return false;
      }
    }().whenComplete(() => _refreshing = null);
  }

  // ───────────── generic verbs ─────────────

  static Future<Map<String, dynamic>> getMap(
    String path, {
    Map<String, String>? query,
  }) async => _asMap(await _request('GET', path, query: query));

  static Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, String>? query,
  }) async {
    final result = await _request('GET', path, query: query);
    if (result is! List) {
      throw const QueueCareApiException('Expected a list from QueueCare API.');
    }
    return result.map((row) => _asMap(row)).toList();
  }

  /// GET that returns either a JSON object or null (e.g. "no triage yet").
  static Future<Map<String, dynamic>?> getMapOrNull(String path) async {
    final result = await _request('GET', path);
    return result is Map<String, dynamic> && result.isNotEmpty ? result : null;
  }

  static Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? body,
  }) async => _asMap(await _request('POST', path, body: body ?? {}));

  /// POST whose response is a JSON array.
  static Future<List<Map<String, dynamic>>> postList(
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final result = await _request('POST', path, body: body ?? {});
    if (result is! List) {
      throw const QueueCareApiException('Expected a list from QueueCare API.');
    }
    return result.map((row) => _asMap(row)).toList();
  }

  static Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      _asMap(await _request('PUT', path, body: body));

  static Future<Map<String, dynamic>> patch(
    String path, {
    Object? body,
  }) async => _asMap(await _request('PATCH', path, body: body));

  static Future<Map<String, dynamic>> delete(String path) async =>
      _asMap(await _request('DELETE', path));

  // ───────────── files ─────────────

  static Future<Map<String, dynamic>> uploadFile(
    String path, {
    required Uint8List bytes,
    required String fileName,
    String field = 'image',
    Map<String, String> fields = const {},
  }) async {
    Future<http.StreamedResponse> send() {
      final request = http.MultipartRequest('POST', _apiUri(path))
        ..headers['Accept'] = 'application/json'
        ..headers['Authorization'] = 'Bearer ${accessToken ?? ''}'
        ..fields.addAll(fields)
        ..files.add(
          http.MultipartFile.fromBytes(field, bytes, filename: fileName),
        );
      return _client.send(request).timeout(const Duration(seconds: 60));
    }

    try {
      var response = await send();
      if (response.statusCode == 401 && await _refresh())
        response = await send();
      final body = await response.stream.bytesToString();
      final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        _handleAuthFailure(response.statusCode, decoded);
        throw _exceptionFrom(response.statusCode, decoded);
      }
      return _asMap(decoded);
    } on QueueCareApiException {
      rethrow;
    } catch (_) {
      throw const QueueCareApiException(
        'Could not upload this file. Check the connection and try again.',
        isNetwork: true,
      );
    }
  }

  static Future<Map<String, dynamic>> uploadMedicalRecord({
    required Uint8List image,
    required String fileName,
    required String recordType,
    required String title,
    String? appointmentId,
  }) => uploadFile(
    '/api/v1/patient/medical-records',
    bytes: image,
    fileName: fileName,
    fields: {
      'record_type': recordType,
      'title': title,
      if (appointmentId != null && appointmentId.isNotEmpty)
        'appointment_id': appointmentId,
    },
  );

  /// Downloads protected bytes (photos, medical images, PDFs).
  static Future<Uint8List> getBytes(String path) async {
    Future<http.Response> send() => _client
        .get(
          _apiUri(path),
          headers: {
            if (accessToken != null) 'Authorization': 'Bearer $accessToken',
          },
        )
        .timeout(const Duration(seconds: 45));
    try {
      var response = await send();
      if (response.statusCode == 401 && await _refresh())
        response = await send();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        dynamic decoded;
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {}
        _handleAuthFailure(response.statusCode, decoded);
        throw _exceptionFrom(response.statusCode, decoded);
      }
      return response.bodyBytes;
    } on QueueCareApiException {
      rethrow;
    } catch (_) {
      throw const QueueCareApiException(
        'Could not load this file. Check your connection.',
        isNetwork: true,
      );
    }
  }

  static Future<Uint8List> getImage(String path) => getBytes(path);

  // ───────────── plumbing ─────────────

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    throw const QueueCareApiException(
      'Unexpected response from QueueCare API.',
    );
  }

  static void _handleAuthFailure(int status, dynamic decoded) {
    if (status == 401 && accessToken != null) {
      _clear();
      _events.add('expired');
    }
  }

  static QueueCareApiException _exceptionFrom(int status, dynamic decoded) {
    final detail = decoded is Map ? decoded['detail'] : null;
    if (detail is Map) {
      return QueueCareApiException(
        (detail['message'] ?? 'Request failed ($status).').toString(),
        statusCode: status,
        code: detail['code']?.toString(),
        data: Map<String, dynamic>.from(detail),
      );
    }
    if (detail is List && detail.isNotEmpty) {
      // FastAPI validation errors: show the first one in plain words.
      final first = detail.first;
      final msg = first is Map
          ? (first['msg'] ?? '').toString()
          : first.toString();
      return QueueCareApiException(
        'Please check what you entered. ${msg.replaceFirst('Value error, ', '')}'
            .trim(),
        statusCode: status,
      );
    }
    return QueueCareApiException(
      detail?.toString() ?? 'Request failed ($status).',
      statusCode: status,
    );
  }

  static Future<dynamic> _request(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool authenticated = true,
    bool retryOn401 = true,
  }) async {
    Future<http.Response> send() {
      final parsed = _apiUri(path);
      final uri = query == null
          ? parsed
          : parsed.replace(queryParameters: query);
      final headers = <String, String>{'Accept': 'application/json'};
      if (body != null) headers['Content-Type'] = 'application/json';
      if (authenticated && accessToken != null) {
        headers['Authorization'] = 'Bearer $accessToken';
      }
      const timeout = Duration(seconds: 25);
      switch (method) {
        case 'POST':
          return _client
              .post(uri, headers: headers, body: jsonEncode(body))
              .timeout(timeout);
        case 'GET':
          return _client.get(uri, headers: headers).timeout(timeout);
        case 'PUT':
          return _client
              .put(uri, headers: headers, body: jsonEncode(body))
              .timeout(timeout);
        case 'PATCH':
          return _client
              .patch(uri, headers: headers, body: jsonEncode(body))
              .timeout(timeout);
        case 'DELETE':
          return _client.delete(uri, headers: headers).timeout(timeout);
        default:
          throw const QueueCareApiException('Unsupported request method.');
      }
    }

    http.Response response;
    try {
      response = await send();
      if (response.statusCode == 401 &&
          authenticated &&
          retryOn401 &&
          accessToken != null &&
          await _refresh()) {
        response = await send();
      }
    } on QueueCareApiException {
      rethrow;
    } catch (_) {
      throw const QueueCareApiException(
        'Could not connect to QueueCare. Check your connection and try again.',
        isNetwork: true,
      );
    }

    dynamic decoded;
    try {
      decoded = response.body.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
    } catch (_) {
      decoded = <String, dynamic>{};
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (authenticated) _handleAuthFailure(response.statusCode, decoded);
      throw _exceptionFrom(response.statusCode, decoded);
    }
    return decoded;
  }

  static Uri _apiUri(String path, {Map<String, String>? query}) {
    final base = Uri.tryParse(baseUrl);
    if (base == null ||
        !base.hasAuthority ||
        base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty) {
      throw const QueueCareApiException('QueueCare API address is invalid.');
    }
    const localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};
    final localDebugHttp =
        !kReleaseMode &&
        base.scheme == 'http' &&
        localHosts.contains(base.host);
    if (base.scheme != 'https' && !localDebugHttp) {
      throw const QueueCareApiException(
        'QueueCare requires a secure HTTPS connection. Contact your clinic for help.',
      );
    }
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    return base.replace(
      path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$normalizedPath',
      queryParameters: query,
    );
  }
}

class QueueCareApiException implements Exception {
  const QueueCareApiException(
    this.message, {
    this.statusCode,
    this.code,
    this.data,
    this.isNetwork = false,
  });
  final String message;
  final int? statusCode;

  /// Machine-readable reason such as `possible_duplicate` or `mfa_required`.
  final String? code;
  final Map<String, dynamic>? data;
  final bool isNetwork;

  @override
  String toString() => message;
}
