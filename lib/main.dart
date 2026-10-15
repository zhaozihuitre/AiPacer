import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'pages/ai_chat_page.dart';
import 'pages/login_page.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/session_store.dart';
import 'widgets/tech_ui.dart';

/// アプリ全体の navigator。セッション切れのとき、どの画面からでもログイン画面に戻す。
final appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  // SharedPreferences / SecureStorage の初期化に binding が必要
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: AppColors.bg0,
    systemNavigationBarIconBrightness: Brightness.light,
  ));
  runApp(const AiPacerApp());
}

class AiPacerApp extends StatefulWidget {
  const AiPacerApp({super.key, this.home});

  /// テストでは home を差し替えてログインを飛ばせる。
  final Widget? home;

  @override
  State<AiPacerApp> createState() => _AiPacerAppState();
}

class _AiPacerAppState extends State<AiPacerApp> {
  @override
  void initState() {
    super.initState();
    final auth = AuthManager.instance;
    ApiClient.authDelegate = auth;
    auth.onSessionExpired = _handleSessionExpired;
  }

  Future<void> _handleSessionExpired() async {
    await SessionStore().clear();
    final nav = appNavigatorKey.currentState;
    if (nav == null) return;
    nav.pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginPage()),
      (route) => false,
    );
    final ctx = appNavigatorKey.currentContext;
    if (ctx != null && ctx.mounted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(content: Text('ログインの有効期限が切れました。再度ログインしてください')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI PACER',
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: widget.home ?? const _SessionGate(),
    );
  }
}

/// 起動時にログイン状態を復元する。
/// - token あり → AI 画面
/// - 認証オフのバックエンドで入ったことがある → AI 画面
/// - それ以外 → ログイン画面
class _SessionGate extends StatefulWidget {
  const _SessionGate();

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  late final Future<Widget> _target = _resolve();

  Future<Widget> _resolve() async {
    final auth = await AuthManager.instance.restore();
    if (auth != null) return const AiChatPage();
    if (await SessionStore().enteredWithoutAuth()) return const AiChatPage();
    return const LoginPage();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Widget>(
      future: _target,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: AuroraBackground(
              child: Center(child: AiOrb(size: 96, active: true)),
            ),
          );
        }
        return snapshot.data ?? const LoginPage();
      },
    );
  }
}
