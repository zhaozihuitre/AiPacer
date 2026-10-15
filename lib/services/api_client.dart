import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_client_factory.dart'
    if (dart.library.io) 'http_client_factory_io.dart' as http_factory;

/// ApiClient 取 token / 刷新 token 用的钩子,由 AuthManager 实现。
/// 抽成接口是为了避免 api_client ↔ auth_service 循环依赖。
abstract class ApiAuthDelegate {
  String? get accessToken;

  /// 401 时调用:刷新成功返回 true(ApiClient 会重试一次)。
  Future<bool> refreshAccessToken();

  /// 刷新也失败:会话失效,需要回登录页。
  void onUnauthorized();
}

/// 后端 API 基础客户端。
///
/// baseUrl 默认指向 Cloud Run 域名(Google 签发的正式证书),APK 与 Web 共用。
/// 可用 `--dart-define=API_BASE_URL=...` 覆盖(例如切换到其他环境)。
class ApiClient {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://mdlink-app-backend-cjy6246wiq-an.a.run.app/api/v1',
  );

  /// 全局认证钩子;为 null 时不带 Authorization。
  static ApiAuthDelegate? authDelegate;

  final http.Client _client;

  ApiClient([http.Client? client])
      : _client = client ?? http_factory.createHttpClient();

  /// GET 请求,返回解码后的 JSON Map / List。
  /// 失败抛 ApiException。
  Future<dynamic> get(String path) {
    return _send('GET', path, authenticated: true);
  }

  /// POST JSON。[authenticated]=false 用于登录 / 刷新等不需要 token 的接口。
  Future<dynamic> post(
    String path,
    Object? body, {
    bool authenticated = true,
  }) {
    return _send('POST', path, body: body, authenticated: authenticated);
  }

  /// PUT JSON(需要 token)。
  Future<dynamic> put(String path, Object? body) {
    return _send('PUT', path, body: body, authenticated: true);
  }

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    required bool authenticated,
    bool retried = false,
  }) async {
    final uri = Uri.parse('$baseUrl$path');
    final delegate = authenticated ? authDelegate : null;
    final token = delegate?.accessToken;
    final headers = <String, String>{
      'Accept': 'application/json',
      if (body != null) 'Content-Type': 'application/json',
      if (token != null && token.isNotEmpty) 'Authorization': 'Bearer $token',
    };
    final encoded = body == null ? null : jsonEncode(body);
    final response = switch (method) {
      'POST' => await _client.post(uri, headers: headers, body: encoded),
      'PUT' => await _client.put(uri, headers: headers, body: encoded),
      _ => await _client.get(uri, headers: headers),
    };

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.body.isEmpty ? null : jsonDecode(response.body);
    }
    if (response.statusCode == 401 && delegate != null) {
      if (!retried && await delegate.refreshAccessToken()) {
        return _send(method, path,
            body: body, authenticated: authenticated, retried: true);
      }
      delegate.onUnauthorized();
    }
    String? errorCode;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        errorCode = decoded['errorCode'] as String?;
      }
    } catch (_) {}
    throw ApiException(
      statusCode: response.statusCode,
      message: '$method $path failed: ${response.body}',
      errorCode: errorCode,
    );
  }

  void close() => _client.close();
}

class ApiException implements Exception {
  ApiException({
    required this.statusCode,
    required this.message,
    this.errorCode,
  });

  final int statusCode;
  final String message;

  /// 后端透传的业务错误码(例:invalid_credentials)。
  final String? errorCode;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// 简单单例定位器,允许测试里替换 http.Client。
class ApiClientLocator {
  static ApiClient? _instance;

  static ApiClient get instance => _instance ??= ApiClient();

  static void set(ApiClient client) => _instance = client;

  static void reset() => _instance = null;
}
