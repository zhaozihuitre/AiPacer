import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_theme.dart';

/// 繰り返しアニメーションの全体スイッチ。
///
/// テストでは false にする(繰り返しのアニメーションがあると pumpAndSettle が終わらないため)。
class TechMotion {
  static bool enabled = true;
}

/// 繰り返しアニメーション用の controller を作る。[TechMotion.enabled] が false なら止めたまま。
AnimationController _loop(TickerProvider vsync, Duration period,
    {bool reverse = false}) {
  final c = AnimationController(vsync: vsync, duration: period);
  if (TechMotion.enabled) {
    c.repeat(reverse: reverse);
  } else {
    c.value = 0.35;
  }
  return c;
}

// ---------------------------------------------------------------------------
// 背景
// ---------------------------------------------------------------------------

/// 深い紺の上に、ゆっくり漂うオーロラ(シアン・バイオレット・マゼンタの光)と細い格子を重ねた背景。
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child, this.intensity = 1});

  final Widget child;

  /// 光の強さ(0〜1)。会話中は控えめにして文字を読みやすくする。
  final double intensity;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      _loop(this, const Duration(seconds: 18));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [AppColors.bg1, AppColors.bg0],
            ),
          ),
        ),
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _c,
            builder: (context, _) => CustomPaint(
              painter: _AuroraPainter(_c.value, widget.intensity),
            ),
          ),
        ),
        const RepaintBoundary(child: CustomPaint(painter: _GridPainter())),
        widget.child,
      ],
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t, this.intensity);

  final double t;
  final double intensity;

  void _blob(Canvas canvas, Size size, Offset center, double radius,
      Color color) {
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(colors: [
        color.withValues(alpha: 0.42 * intensity),
        color.withValues(alpha: 0),
      ]).createShader(rect);
    canvas.drawCircle(center, radius, paint);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final w = size.width;
    final h = size.height;
    final r = math.max(w, h) * 0.55;
    _blob(canvas, size,
        Offset(w * (0.15 + 0.12 * math.sin(a)), h * (0.12 + 0.06 * math.cos(a))),
        r, AppColors.cyan);
    _blob(
        canvas,
        size,
        Offset(w * (0.9 + 0.1 * math.cos(a * 1.3)),
            h * (0.35 + 0.08 * math.sin(a * 1.1))),
        r * 0.9,
        AppColors.violet);
    _blob(
        canvas,
        size,
        Offset(w * (0.4 + 0.15 * math.sin(a * 0.7 + 1)),
            h * (1.0 + 0.05 * math.cos(a * 0.9))),
        r * 0.8,
        AppColors.magenta.withValues(alpha: 0.7));
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter old) =>
      old.t != t || old.intensity != intensity;
}

/// 上ほど薄くなる細い格子(ホログラムの床のような雰囲気)。
class _GridPainter extends CustomPainter {
  const _GridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const step = 28.0;
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x00FFFFFF), Color(0x0DFFFFFF)],
      ).createShader(Offset.zero & size)
      ..strokeWidth = 0.6;
    for (var x = 0.0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = 0.0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// ガラスの面
// ---------------------------------------------------------------------------

/// すりガラス風の面(背景をぼかし、半透明の白と細い枠線を重ねる)。
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.radius = AppRadius.lg,
    this.color = AppColors.glass,
    this.borderColor = AppColors.border,
    this.glow,
    this.blur = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final Color color;
  final Color borderColor;

  /// 指定すると外側にその色の光をにじませる。
  final Color? glow;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          if (glow != null)
            BoxShadow(
              color: glow!.withValues(alpha: 0.25),
              blurRadius: 28,
              spreadRadius: -4,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: color,
              borderRadius: borderRadius,
              border: Border.all(color: borderColor),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// AI の光球
// ---------------------------------------------------------------------------

/// AI を表す光球。回転するネオンの輪と、脈打つ核。
/// [active] のときは速く回り、光が強くなる(回答作成中など)。
class AiOrb extends StatefulWidget {
  const AiOrb({super.key, this.size = 120, this.active = false});

  final double size;
  final bool active;

  @override
  State<AiOrb> createState() => _AiOrbState();
}

class _AiOrbState extends State<AiOrb> with TickerProviderStateMixin {
  late final AnimationController _spin =
      _loop(this, const Duration(seconds: 8));
  late final AnimationController _pulse =
      _loop(this, const Duration(milliseconds: 2400), reverse: true);

  @override
  void initState() {
    super.initState();
    _applySpeed();
  }

  @override
  void didUpdateWidget(covariant AiOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _applySpeed();
  }

  void _applySpeed() {
    _spin.duration =
        widget.active ? const Duration(seconds: 2) : const Duration(seconds: 8);
    if (TechMotion.enabled) _spin.repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: widget.size,
        child: AnimatedBuilder(
          animation: Listenable.merge([_spin, _pulse]),
          builder: (context, _) => CustomPaint(
            painter: _OrbPainter(
              spin: _spin.value,
              pulse: _pulse.value,
              active: widget.active,
            ),
          ),
        ),
      ),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({required this.spin, required this.pulse, required this.active});

  final double spin;
  final double pulse;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final glowBoost = active ? 1.0 : 0.65;

    // 外側のにじみ
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [
          AppColors.violet.withValues(alpha: 0.45 * glowBoost),
          AppColors.cyan.withValues(alpha: 0.12 * glowBoost),
          Colors.transparent,
        ], stops: const [0.35, 0.7, 1]).createShader(
            Rect.fromCircle(center: c, radius: r)),
    );

    // 回転するネオンの輪
    final ringR = r * 0.66;
    final ringRect = Rect.fromCircle(center: c, radius: ringR);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.06
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: const [
          AppColors.cyan,
          AppColors.violet,
          AppColors.magenta,
          Colors.transparent,
          AppColors.cyan,
        ],
        stops: const [0, 0.35, 0.6, 0.8, 1],
        transform: GradientRotation(spin * 2 * math.pi),
      ).createShader(ringRect);
    canvas.drawCircle(c, ringR, ring);

    // 逆回りの細い輪
    final thin = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.015
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          AppColors.cyan.withValues(alpha: 0.9),
          Colors.transparent,
        ],
        transform: GradientRotation(-spin * 4 * math.pi),
      ).createShader(Rect.fromCircle(center: c, radius: r * 0.8));
    canvas.drawCircle(c, r * 0.8, thin);

    // 脈打つ核
    final coreR = r * (0.40 + 0.04 * pulse);
    canvas.drawCircle(
      c,
      coreR,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.35),
          colors: [
            Colors.white.withValues(alpha: 0.95),
            AppColors.cyan,
            AppColors.violet,
            const Color(0xFF2A1458),
          ],
          stops: const [0, 0.25, 0.65, 1],
        ).createShader(Rect.fromCircle(center: c, radius: coreR)),
    );
  }

  @override
  bool shouldRepaint(covariant _OrbPainter old) =>
      old.spin != spin || old.pulse != pulse || old.active != active;
}

// ---------------------------------------------------------------------------
// 文字・ボタン
// ---------------------------------------------------------------------------

/// グラデーションで塗った文字。
class GradientText extends StatelessWidget {
  const GradientText(
    this.text, {
    super.key,
    required this.style,
    this.gradient = kNeonGradient,
    this.textAlign,
  });

  final String text;
  final TextStyle style;
  final Gradient gradient;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => gradient.createShader(Offset.zero & bounds.size),
      child: Text(text, style: style, textAlign: textAlign),
    );
  }
}

/// グラデーションで光る主ボタン。
class NeonButton extends StatelessWidget {
  const NeonButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.height = 50,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    final radius = BorderRadius.circular(AppRadius.md);
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onPressed == null && !loading ? 0.5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: kNeonGradient,
            borderRadius: radius,
            boxShadow: [
              BoxShadow(
                color: AppColors.cyan.withValues(alpha: 0.35),
                blurRadius: 22,
                offset: const Offset(-4, 6),
                spreadRadius: -6,
              ),
              BoxShadow(
                color: AppColors.violet.withValues(alpha: 0.45),
                blurRadius: 22,
                offset: const Offset(4, 8),
                spreadRadius: -6,
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: radius,
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: height,
                child: Center(
                  child: loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[
                              Icon(icon, color: Colors.white, size: 18),
                              const SizedBox(width: 8),
                            ],
                            Text(
                              label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 丸いガラスのアイコンボタン(上部のツールバー用)。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.color = AppColors.text,
    this.size = 40,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: AppColors.glass,
          shape: const CircleBorder(side: BorderSide(color: AppColors.border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox.square(
              dimension: size,
              child: Icon(
                icon,
                size: size * 0.48,
                color: enabled ? color : AppColors.mutedText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 状態表示
// ---------------------------------------------------------------------------

/// 順番に明滅する 3 つの点(考え中の表示)。
class PulseDots extends StatefulWidget {
  const PulseDots({super.key, this.color = AppColors.cyan, this.size = 5});

  final Color color;
  final double size;

  @override
  State<PulseDots> createState() => _PulseDotsState();
}

class _PulseDotsState extends State<PulseDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      _loop(this, const Duration(milliseconds: 1200));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: widget.size * 0.35),
              child: Opacity(
                opacity: 0.25 +
                    0.75 *
                        (0.5 +
                            0.5 *
                                math.sin((_c.value - i * 0.18) * 2 * math.pi)),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(color: widget.color, blurRadius: 6),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 音声の波形(読み上げ中・聞き取り中に揺れる縦棒)。
class WaveBars extends StatefulWidget {
  const WaveBars({
    super.key,
    this.playing = false,
    this.color = AppColors.cyan,
    this.bars = 18,
    this.height = 22,
  });

  final bool playing;
  final Color color;
  final int bars;
  final double height;

  @override
  State<WaveBars> createState() => _WaveBarsState();
}

class _WaveBarsState extends State<WaveBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      _loop(this, const Duration(milliseconds: 1400));

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (var i = 0; i < widget.bars; i++)
              Container(
                width: 2.5,
                height: widget.height *
                    (widget.playing
                        ? 0.25 +
                            0.75 *
                                (0.5 +
                                    0.5 *
                                        math.sin(_c.value * 2 * math.pi * 2 +
                                            i * 0.7)).abs()
                        : 0.18 + 0.12 * math.sin(i * 1.3).abs()),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  color: widget.playing
                      ? Color.lerp(AppColors.cyan, AppColors.violet,
                          i / widget.bars)
                      : AppColors.borderStrong,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 小さな等幅のラベル(例:「● ONLINE」)。
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    this.color = AppColors.success,
  });

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: color, blurRadius: 6)],
            ),
          ),
          const SizedBox(width: 6),
          Text(label, style: monoStyle(size: 9.5, color: color)),
        ],
      ),
    );
  }
}
