import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import 'api_client.dart';

/// 登录用户信息。
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    this.firstName = '',
    this.lastName = '',
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
        id: json['id'] as String? ?? '',
        email: json['email'] as String? ?? '',
        firstName: json['firstName'] as String? ?? '',
        lastName: json['lastName'] as String? ?? '',
      );

  final String id;
  final String email;
  final String firstName;
  final String lastName;

  String get displayName {
    final name = '$lastName $firstName'.trim();
    return name.isEmpty ? email : name;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'firstName': firstName,
        'lastName': lastName,
      };
}

/// 后端 /auth/* 返回的会话。
class AuthSession {
  const AuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.user,
    this.organizationId,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
        accessToken: json['accessToken'] as String? ?? '',
        refreshToken: json['refreshToken'] as String? ?? '',
        organizationId: json['organizationId'] as String?,
        user: AuthUser.fromJson(
          (json['user'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );

  final String accessToken;
  final String refreshToken;
  final String? organizationId;
  final AuthUser user;

  Map<String, dynamic> toJson() => {
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'organizationId': organizationId,
        'user': user.toJson(),
      };
}

/// 登录失败(显示给用户的 message 已本地化)。
class AuthException implements Exception {
  const AuthException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => 'AuthException($code): $message';
}

/// 用户在浏览器里取消了登录。
class AuthCancelledException implements Exception {
  const AuthCancelledException();
}

/// 浏览器 OAuth 登录的外部 IdP。[workosName] 是 WorkOS authorize 的 provider 参数。
enum OAuthProvider {
  microsoft('MicrosoftOAuth'),
  google('GoogleOAuth');

  const OAuthProvider(this.workosName);
  final String workosName;
}

/// 认证数据源抽象:目前走自家后端(后端再对接 WorkOS),测试里可替换。
abstract class AuthGateway {
  /// 后端是否开启了认证(WorkOS 未配置时为 false)。
  Future<bool> isEnabled();
  Future<AuthSession> signInWithPassword(String email, String password);
  Future<AuthSession> signInWithOAuth(OAuthProvider provider);
  Future<AuthSession> refresh(String refreshToken);
  Future<void> signOut();
}

/// 通过后端 /api/v1/auth/* 登录。WorkOS API key 只在后端。
/// 打开浏览器登录并返回回调 URL。测试时替换,避免真的打开浏览器。
typedef WebAuthenticate = Future<String> Function(
    String url, String callbackUrlScheme);

Future<String> _flutterWebAuthenticate(String url, String callbackUrlScheme) {
  return FlutterWebAuth2.authenticate(
    url: url,
    callbackUrlScheme: callbackUrlScheme,
    // 不共享浏览器 cookie:登出后不会被自动登回同一账号
    options: const FlutterWebAuth2Options(preferEphemeral: true),
  );
}

class BackendAuthGateway implements AuthGateway {
  BackendAuthGateway({ApiClient? api, WebAuthenticate? webAuthenticate})
      : _api = api,
        _webAuthenticate = webAuthenticate ?? _flutterWebAuthenticate;

  final ApiClient? _api;
  final WebAuthenticate _webAuthenticate;
  ApiClient get api => _api ?? ApiClientLocator.instance;

  /// 原生端回调 scheme,需与 AndroidManifest / WorkOS Redirect URI 一致。
  static const callbackScheme = 'com.retailai.mdlink';
  static const nativeRedirectUri = '$callbackScheme://auth/callback';

  static String get redirectUri =>
      kIsWeb ? '${Uri.base.origin}/auth.html' : nativeRedirectUri;

  @override
  Future<bool> isEnabled() async {
    final Map<String, dynamic> res;
    try {
      res = await api.get('/auth/config') as Map<String, dynamic>;
    } on ApiException catch (e) {
      // 旧版后端没有 /auth/config:视为认证未开启
      if (e.statusCode == 404) return false;
      rethrow;
    }
    final data = (res['data'] as Map?)?.cast<String, dynamic>() ?? const {};
    return data['enabled'] == true;
  }

  @override
  Future<AuthSession> signInWithPassword(String email, String password) {
    return _session(() => api.post(
          '/auth/login',
          {'email': email, 'password': password},
          authenticated: false,
        ));
  }

  @override
  Future<AuthSession> signInWithOAuth(OAuthProvider provider) async {
    final verifier = _randomString(64);
    final challenge = base64UrlEncode(
      sha256.convert(utf8.encode(verifier)).bytes,
    ).replaceAll('=', '');
    final state = _randomString(24);

    final res = await _call(() => api.post(
          '/auth/authorize-url',
          {
            'provider': provider.workosName,
            'redirectUri': redirectUri,
            'state': state,
            'codeChallenge': challenge,
          },
          authenticated: false,
        ));
    final url = ((res['data'] as Map?)?['url'] as String?) ?? '';
    if (url.isEmpty) {
      throw const AuthException('ログインURLの取得に失敗しました');
    }

    final String result;
    try {
      result = await _webAuthenticate(url, callbackScheme);
    } on PlatformException catch (e) {
      if (e.code == 'CANCELED') throw const AuthCancelledException();
      throw AuthException('ログイン画面を開けませんでした', code: e.code);
    } catch (_) {
      // MissingPluginException 等:浏览器无法打开
      throw const AuthException('ログイン画面を開けませんでした');
    }

    final params = Uri.parse(result).queryParameters;
    if (params['error'] != null) {
      throw AuthException(
        params['error_description'] ?? 'ログインに失敗しました',
        code: params['error'],
      );
    }
    if (params['state'] != state) {
      throw const AuthException('ログイン状態が一致しません。もう一度お試しください');
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const AuthException('ログインに失敗しました');
    }
    return _session(() => api.post(
          '/auth/token',
          {'code': code, 'codeVerifier': verifier},
          authenticated: false,
        ));
  }

  @override
  Future<AuthSession> refresh(String refreshToken) {
    return _session(() => api.post(
          '/auth/refresh',
          {'refreshToken': refreshToken},
          authenticated: false,
        ));
  }

  @override
  Future<void> signOut() async {
    try {
      await api.post('/auth/logout', null);
    } catch (_) {
      // 服务端注销失败不影响本地登出
    }
  }

  Future<AuthSession> _session(Future<dynamic> Function() request) async {
    final res = await _call(request);
    final data = (res['data'] as Map?)?.cast<String, dynamic>();
    if (data == null) throw const AuthException('ログインに失敗しました');
    return AuthSession.fromJson(data);
  }

  Future<Map<String, dynamic>> _call(Future<dynamic> Function() request) async {
    try {
      return (await request() as Map).cast<String, dynamic>();
    } on ApiException catch (e) {
      throw AuthException(_messageFor(e), code: e.errorCode);
    } on AuthException {
      rethrow;
    } catch (_) {
      throw const AuthException('通信に失敗しました。通信状態を確認してください');
    }
  }

  static String _messageFor(ApiException e) {
    switch (e.errorCode) {
      case 'invalid_credentials':
        return 'メールアドレスまたはパスワードが正しくありません';
      case 'email_verification_required':
        // 邮箱验证由管理员在 WorkOS 建用户时完成,App 不提供验证码输入
        return 'メールアドレスの確認が完了していません。管理者にお問い合わせください';
      case 'not_allowed':
        return 'このアカウントではログインできません。会社のメールアドレスでログインしてください';
      case 'mfa_enrollment':
      case 'mfa_challenge':
        return '多要素認証が必要です。管理者にお問い合わせください';
      case 'organization_selection_required':
        return '所属組織の選択が必要です。管理者にお問い合わせください';
    }
    switch (e.statusCode) {
      case 401:
        return 'メールアドレスまたはパスワードが正しくありません';
      case 403:
        return 'このアカウントではログインできません。会社のメールアドレスでログインしてください';
      case 503:
        return '認証サービスが設定されていません';
      case 400:
        return '入力内容を確認してください';
    }
    return 'ログインに失敗しました(${e.statusCode})';
  }

  static String _randomString(int length) {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }
}

/// 会话持久化(Android Keystore / iOS Keychain 加密)。
class AuthStore {
  AuthStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _kSession = 'auth.session';
  final FlutterSecureStorage _storage;

  Future<AuthSession?> read() async {
    try {
      final raw = await _storage.read(key: _kSession);
      if (raw == null || raw.isEmpty) return null;
      return AuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(AuthSession session) =>
      _storage.write(key: _kSession, value: jsonEncode(session.toJson()));

  Future<void> clear() => _storage.delete(key: _kSession);
}

/// 全局登录态:持有当前 session,给 ApiClient 提供 token 与刷新。
class AuthManager implements ApiAuthDelegate {
  AuthManager({AuthGateway? gateway, AuthStore? store})
      : gateway = gateway ?? BackendAuthGateway(),
        _store = store ?? AuthStore();

  static AuthManager instance = AuthManager();

  AuthGateway gateway;
  final AuthStore _store;

  AuthSession? _session;
  bool _persist = true;
  Future<bool>? _refreshing;

  /// 会话失效(刷新失败)时回调,由 App 导航回登录页。
  VoidCallback? onSessionExpired;

  AuthSession? get session => _session;
  bool get isSignedIn => _session != null;

  @override
  String? get accessToken => _session?.accessToken;

  /// 启动时从安全存储恢复。
  Future<AuthSession?> restore() async {
    _session = await _store.read();
    _persist = true;
    _expiredNotified = false;
    return _session;
  }

  /// 登录成功后调用;[persist]=false 时只保存在内存(「ログイン状態を保持する」未勾选)。
  Future<void> setSession(AuthSession session, {required bool persist}) async {
    _session = session;
    _persist = persist;
    _expiredNotified = false;
    if (persist) {
      await _store.save(session);
    } else {
      await _store.clear();
    }
  }

  Future<void> signOut() async {
    if (_session != null) await gateway.signOut();
    _session = null;
    await _store.clear();
  }

  /// 并发 401 只刷新一次:WorkOS 的 refresh token 是一次性的,重复用会失败。
  @override
  Future<bool> refreshAccessToken() {
    return _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);
  }

  Future<bool> _doRefresh() async {
    final current = _session;
    if (current == null || current.refreshToken.isEmpty) return false;
    try {
      final next = await gateway.refresh(current.refreshToken);
      await setSession(next, persist: _persist);
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _expiredNotified = false;

  @override
  void onUnauthorized() {
    // 并发请求同时 401 时只通知一次;下次 setSession 后复位
    if (_expiredNotified) return;
    _expiredNotified = true;
    _session = null;
    unawaited(_store.clear());
    onSessionExpired?.call();
  }
}
