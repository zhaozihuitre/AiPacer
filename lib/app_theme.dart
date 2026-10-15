import 'package:flutter/material.dart';

/// AI PACER のデザイントークン(ダーク・ネオン調)。
///
/// 背景は深い紺、強調色はシアン → バイオレットのグラデーション。
/// 面はガラス風(半透明の白 + 細い枠線)で重ねる。
class AppColors {
  // 背景
  static const bg0 = Color(0xFF04060D);
  static const bg1 = Color(0xFF0A1022);
  static const background = bg0;

  // ネオンの強調色
  static const cyan = Color(0xFF22D3EE);
  static const violet = Color(0xFF8B5CF6);
  static const magenta = Color(0xFFE879F9);
  static const primary = cyan;

  // 面・枠
  static const glass = Color(0x0FFFFFFF); // 白 6%
  static const glassStrong = Color(0x1AFFFFFF); // 白 10%
  static const border = Color(0x1FFFFFFF); // 白 12%
  static const borderStrong = Color(0x33FFFFFF); // 白 20%

  // 文字
  static const text = Color(0xFFE8ECF7);
  static const secondaryText = Color(0xFF8E97B0);
  static const mutedText = Color(0xFF5B6480);

  // 状態
  static const success = Color(0xFF34D399);
  static const warning = Color(0xFFFBBF24);
  static const error = Color(0xFFF87171);

  // グラフ(ai_chart_view)が使う名前
  static const slate900 = Color(0xFF111833); // ツールチップの背景
  static const statusChipBgNeutral = Color(0x1FFFFFFF); // 横棒の地
}

/// シアン → バイオレットの基本グラデーション。
const kNeonGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [AppColors.cyan, AppColors.violet],
);

/// バイオレット → マゼンタ(利用者の吹き出しなど)。
const kUserGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xFF3B82F6), AppColors.violet],
);

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

class AppRadius {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 20;
}

/// 等幅の数字・英字(ラベル・時刻など、計器っぽく見せたい所)。
const kMonoFamilyFallback = ['monospace', 'Roboto Mono', 'Menlo'];

TextStyle monoStyle({
  double size = 11,
  Color color = AppColors.secondaryText,
  FontWeight weight = FontWeight.w500,
  double letterSpacing = 1.2,
}) =>
    TextStyle(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      fontFamilyFallback: kMonoFamilyFallback,
    );

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.cyan,
    onPrimary: AppColors.bg0,
    secondary: AppColors.violet,
    onSecondary: Colors.white,
    surface: AppColors.bg1,
    onSurface: AppColors.text,
    error: AppColors.error,
  );
  const inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
    borderSide: BorderSide(color: AppColors.border),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'Noto Sans JP',
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg0,
    canvasColor: AppColors.bg1,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    iconTheme: const IconThemeData(color: AppColors.text),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.glass,
      hintStyle: const TextStyle(color: AppColors.mutedText, fontSize: 13),
      prefixIconColor: AppColors.secondaryText,
      suffixIconColor: AppColors.secondaryText,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.cyan, width: 1.4),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.error),
      ),
      focusedErrorBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.error, width: 1.4),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: AppColors.slate900,
      contentTextStyle: TextStyle(color: AppColors.text, fontSize: 13),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.bg1,
      surfaceTintColor: Colors.transparent,
      dragHandleColor: AppColors.borderStrong,
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.bg1,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: AppColors.slate900,
      surfaceTintColor: Colors.transparent,
    ),
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.slate900,
        borderRadius: BorderRadius.all(Radius.circular(6)),
      ),
      textStyle: TextStyle(color: AppColors.text, fontSize: 11),
    ),
    progressIndicatorTheme:
        const ProgressIndicatorThemeData(color: AppColors.cyan),
    checkboxTheme: CheckboxThemeData(
      side: const BorderSide(color: AppColors.borderStrong),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected)
            ? AppColors.cyan
            : Colors.transparent,
      ),
      checkColor: const WidgetStatePropertyAll(AppColors.bg0),
    ),
  );
}
