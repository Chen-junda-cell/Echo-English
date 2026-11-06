import 'package:flutter/material.dart';

class AppColors {
  static const primary = Color(0xFF2F6FED);
  static const ink = Color(0xFF14171C);
  static const sub = Color(0xFF6B7280);
  static const line = Color(0xFFE8EAEE);
  static const bg = Color(0xFFF7F8FA);
  static const ok = Color(0xFF12A150);
  static const warn = Color(0xFFE0A400);
  static const danger = Color(0xFFE5484D);
  static const aiBubble = Color(0xFFEDF3FF);
}

class TextStyles {
  static const h1 = TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const h2 = TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: AppColors.ink);
  static const body = TextStyle(fontSize: 15, height: 1.5, color: AppColors.ink);
  static const small = TextStyle(fontSize: 12.5, height: 1.4, color: AppColors.sub);
  static const mono = TextStyle(fontSize: 13, height: 1.45, fontFamily: 'monospace', color: AppColors.ink);
}

/// 间距速记：Gap.h16 之类可直接当 widget 用
abstract final class Gap {
  static const Widget h2 = SizedBox(height: 2);
  static const Widget h4 = SizedBox(height: 4);
  static const Widget h6 = SizedBox(height: 6);
  static const Widget h8 = SizedBox(height: 8);
  static const Widget h12 = SizedBox(height: 12);
  static const Widget h16 = SizedBox(height: 16);
  static const Widget h24 = SizedBox(height: 24);
  static const Widget h32 = SizedBox(height: 32);
  static const Widget w4 = SizedBox(width: 4);
  static const Widget w6 = SizedBox(width: 6);
  static const Widget w8 = SizedBox(width: 8);
  static const Widget w12 = SizedBox(width: 12);
  static const Widget w16 = SizedBox(width: 16);
}

/// 一行小标题 + 右侧操作
class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing, this.padding});

  final String title;
  final Widget? trailing;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(0, 4, 0, 10),
      child: Row(
        children: [
          Text(title, style: TextStyles.h2),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 空状态占位
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 46, color: AppColors.line),
            const SizedBox(height: 16),
            Text(title, style: TextStyles.h2, textAlign: TextAlign.center),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, style: TextStyles.small, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      primary: AppColors.primary,
      surface: Colors.white,
    ),
    scaffoldBackgroundColor: AppColors.bg,
  );
  return base.copyWith(
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyles.h1,
      iconTheme: IconThemeData(color: AppColors.ink),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: AppColors.line),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      side: const BorderSide(color: AppColors.line),
      backgroundColor: Colors.white,
      labelStyle: const TextStyle(fontSize: 13, color: AppColors.ink),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.line, thickness: 1, space: 1),
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.sub,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );
}