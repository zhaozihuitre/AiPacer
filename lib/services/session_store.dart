import 'package:shared_preferences/shared_preferences.dart';

/// 認証オフのバックエンドでログイン画面を通過したかを覚える(SharedPreferences)。
///
/// token などの機密情報はここに置かず、AuthStore(安全な保存領域)に置く。
/// 認証オンのときは token の有無だけで起動画面を決めるので、ここは使わない。
class SessionStore {
  static const _kAuthMode = 'session.authMode';

  /// 認証オフのまま入ったことがあるか。
  Future<bool> enteredWithoutAuth() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kAuthMode) == 'none';
  }

  Future<void> markEnteredWithoutAuth() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAuthMode, 'none');
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAuthMode);
  }
}
