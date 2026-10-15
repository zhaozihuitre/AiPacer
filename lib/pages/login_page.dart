import 'package:flutter/material.dart';

import '../app_theme.dart';
import '../services/auth_service.dart';
import '../services/session_store.dart';
import '../widgets/tech_ui.dart';
import 'ai_chat_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _rememberLogin = true;
  bool _obscurePassword = true;
  bool _submitting = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// メールアドレス + パスワードでログイン(WorkOS、バックエンド経由)。
  Future<void> _login() async {
    if (_submitting) return;
    if (!_formKey.currentState!.validate()) return;
    await _runSignIn((gateway) => gateway.signInWithPassword(
          _emailController.text.trim(),
          _passwordController.text,
        ));
  }

  /// Microsoft / Google アカウントでログイン(ブラウザ OAuth + PKCE)。
  Future<void> _loginWithOAuth(OAuthProvider provider) async {
    if (_submitting) return;
    await _runSignIn((gateway) => gateway.signInWithOAuth(provider),
        requireAuth: true);
  }

  /// [requireAuth]=true:認証オフのときは進めない(外部アカウントのログインには代わりの経路が無い)。
  Future<void> _runSignIn(
    Future<AuthSession> Function(AuthGateway gateway) signIn, {
    bool requireAuth = false,
  }) async {
    setState(() => _submitting = true);
    try {
      final auth = AuthManager.instance;
      final bool enabled;
      try {
        enabled = await auth.gateway.isEnabled();
      } catch (_) {
        _showMessage('通信に失敗しました。通信状態を確認してください。');
        return;
      }
      if (enabled) {
        final session = await signIn(auth.gateway);
        await auth.setSession(session, persist: _rememberLogin);
      } else if (requireAuth) {
        _showMessage('認証サービスが設定されていません');
        return;
      } else {
        // 認証オフのバックエンド:そのまま入り、次回の起動でもログイン画面を出さない
        await SessionStore().markEnteredWithoutAuth();
      }

      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder<void>(
          transitionDuration: const Duration(milliseconds: 500),
          pageBuilder: (_, __, ___) => const AiChatPage(),
          transitionsBuilder: (_, animation, __, child) =>
              FadeTransition(opacity: animation, child: child),
        ),
        (route) => false,
      );
    } on AuthCancelledException {
      // ブラウザを閉じられたときは何も出さない
    } on AuthException catch (e) {
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuroraBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Column(
                  children: [
                    const _Hero(),
                    const SizedBox(height: 28),
                    _LoginCard(
                      formKey: _formKey,
                      emailController: _emailController,
                      passwordController: _passwordController,
                      rememberLogin: _rememberLogin,
                      obscurePassword: _obscurePassword,
                      onRememberChanged: (value) =>
                          setState(() => _rememberLogin = value ?? false),
                      onTogglePassword: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                      submitting: _submitting,
                      onLogin: _login,
                      onMicrosoftLogin: () =>
                          _loginWithOAuth(OAuthProvider.microsoft),
                      onGoogleLogin: () =>
                          _loginWithOAuth(OAuthProvider.google),
                    ),
                    const SizedBox(height: 24),
                    const _Footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 光球・ロゴ・キャッチコピー。
class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const AiOrb(size: 132),
        const SizedBox(height: 8),
        const GradientText(
          'AI PACER',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w900,
            letterSpacing: 6,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'RETAIL INTELLIGENCE ASSISTANT',
          style: monoStyle(size: 10, letterSpacing: 3),
        ),
        const SizedBox(height: 14),
        const Text(
          '売上・在庫・商圏データに、\n話しかけるだけでアクセス。',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.text,
            fontSize: 15,
            height: 1.6,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.rememberLogin,
    required this.obscurePassword,
    required this.onRememberChanged,
    required this.onTogglePassword,
    required this.submitting,
    required this.onLogin,
    required this.onMicrosoftLogin,
    required this.onGoogleLogin,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool rememberLogin;
  final bool obscurePassword;
  final ValueChanged<bool?> onRememberChanged;
  final VoidCallback onTogglePassword;
  final bool submitting;
  final VoidCallback onLogin;
  final VoidCallback onMicrosoftLogin;
  final VoidCallback onGoogleLogin;

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
      radius: AppRadius.xl,
      glow: AppColors.violet,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Text(
                'ログイン',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Text('SECURE ACCESS', style: monoStyle(size: 9.5)),
            ],
          ),
          const SizedBox(height: 18),
          Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: emailController,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(color: AppColors.text, fontSize: 14),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'メールアドレスを入力してください'
                      : null,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.alternate_email, size: 20),
                    hintText: 'メールアドレス',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: passwordController,
                  obscureText: obscurePassword,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => onLogin(),
                  style: const TextStyle(color: AppColors.text, fontSize: 14),
                  validator: (value) => value == null || value.isEmpty
                      ? 'パスワードを入力してください'
                      : null,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.lock_outline, size: 20),
                    hintText: 'パスワード',
                    suffixIcon: IconButton(
                      tooltip: obscurePassword ? 'パスワードを表示' : 'パスワードを隠す',
                      onPressed: onTogglePassword,
                      icon: Icon(
                        obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                InkWell(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  onTap: () => onRememberChanged(!rememberLogin),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        SizedBox.square(
                          dimension: 20,
                          child: Checkbox(
                            value: rememberLogin,
                            onChanged: onRememberChanged,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'ログイン状態を保持する',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: AppColors.secondaryText,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                NeonButton(
                  label: 'ログイン',
                  icon: Icons.arrow_forward_rounded,
                  loading: submitting,
                  onPressed: onLogin,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('OR', style: monoStyle(size: 10)),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _SocialLoginButton(
                  logo: const _BrandLogo(_MicrosoftLogoPainter()),
                  label: 'Microsoft',
                  semanticsLabel: 'Microsoftでログイン',
                  onPressed: submitting ? null : onMicrosoftLogin,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _SocialLoginButton(
                  logo: const _BrandLogo(_GoogleLogoPainter()),
                  label: 'Google',
                  semanticsLabel: 'Googleでログイン',
                  onPressed: submitting ? null : onGoogleLogin,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Microsoft / Google のログインボタン(同じ見た目)。
class _SocialLoginButton extends StatelessWidget {
  const _SocialLoginButton({
    required this.logo,
    required this.label,
    required this.semanticsLabel,
    required this.onPressed,
  });

  final Widget logo;
  final String label;
  final String semanticsLabel;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: semanticsLabel,
      child: SizedBox(
        height: 46,
        child: OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.text,
            backgroundColor: AppColors.glass,
            side: const BorderSide(color: AppColors.border),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              logo,
              const SizedBox(width: 8),
              // 幅の狭い端末では文字を省略する(はみ出さない)
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrandLogo extends StatelessWidget {
  const _BrandLogo(this.painter);

  final CustomPainter painter;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 16,
      height: 16,
      child: CustomPaint(painter: painter),
    );
  }
}

class _MicrosoftLogoPainter extends CustomPainter {
  const _MicrosoftLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    final w = size.width / 2 - 0.5;
    final h = size.height / 2 - 0.5;
    p.color = const Color(0xFFF25022);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), p);
    p.color = const Color(0xFF7FBA00);
    canvas.drawRect(Rect.fromLTWH(w + 1, 0, w, h), p);
    p.color = const Color(0xFF00A4EF);
    canvas.drawRect(Rect.fromLTWH(0, h + 1, w, h), p);
    p.color = const Color(0xFFFFB900);
    canvas.drawRect(Rect.fromLTWH(w + 1, h + 1, w, h), p);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Google の「G」:4 色の円弧と右側の横棒。
class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _yellow = Color(0xFFFBBC05);
  static const _red = Color(0xFFEA4335);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.2;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    const d = 3.141592653589793 / 180;
    void arc(Color c, double fromDeg, double sweepDeg) {
      p.color = c;
      canvas.drawArc(rect, fromDeg * d, sweepDeg * d, false, p);
    }

    arc(_blue, 0, 45);
    arc(_green, 45, 90);
    arc(_yellow, 135, 70);
    arc(_red, 205, 110);
    canvas.drawRect(
      Rect.fromLTWH(size.width / 2, size.height / 2 - stroke / 2,
          size.width / 2, stroke),
      Paint()..color = _blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.bolt, color: AppColors.cyan, size: 14),
        const SizedBox(width: 4),
        Text('POWERED BY e3SMART × CLAUDE', style: monoStyle(size: 9.5)),
      ],
    );
  }
}
