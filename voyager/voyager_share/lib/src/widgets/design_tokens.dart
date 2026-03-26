import 'package:flutter/material.dart';

/// Shared design tokens for the Blackhole white-gray light theme.
///
/// Used by both Horizon and Voyager to guarantee visual consistency.
/// Import this instead of defining local `_C` color classes.
class AppColors {
  AppColors._();

  // ── Backgrounds ──────────────────────────────────────────────
  static const background = Color(0xFFFFFFFF);
  static const surface = Color(0xFFFAFBFC);
  static const surfaceVariant = Color(0xFFF3F4F6);
  static const surfaceBright = Color(0xFFE8EAED);
  static const surfaceDim = Color(0xFFF7F8FA);

  // ── Accent ───────────────────────────────────────────────────
  static const accent = Color(0xFF6B7280);
  static const accentDim = Color(0xFF4B5563);

  // ── Status ───────────────────────────────────────────────────
  static const success = Color(0xFF059669);
  static const error = Color(0xFFDC2626);
  static const warning = Color(0xFF9D3C3C);
  static const statusGreen = Color(0xFF4A7C5E);  // WCAG AA on #FAFBFC (~5.3:1)
  static const statusYellow = Color(0xFF9A8730);  // darkened for AA (~4.8:1)
  static const statusOrange = Color(0xFFA07040);  // darkened for AA (~4.6:1)
  static const statusRed = Color(0xFF9D3C3C);     // WCAG AA on #FAFBFC (~8.9:1)
  static const statusAmber = Color(0xFFF59E0B);  // pairing/pending states

  // ── Text ─────────────────────────────────────────────────────
  static const textPrimary = Color(0xFF111111);
  static const textSecondary = Color(0xFF3A3A3A);
  static const textTertiary = Color(0xFF6B7280);
  static const textMuted = Color(0xFF9CA3AF);
  static const textHint = Color(0xFFD1D5DB);       // placeholder/hint text

  // ── Borders ──────────────────────────────────────────────────
  static const border = Color(0xFFE5E7EB);
  static const borderSubtle = Color(0xFFF0F1F3);
  static const borderFocus = Color(0xFF9CA3AF);
  static const divider = Color(0xFFD1D5DB);         // separators, key borders

  // ── Keyboard/Controls ──────────────────────────────────────
  static const keyBackground = Color(0xFFE5E7EB);
  static const keyPressed = Color(0xFFD1D5DB);
  static const keyBorder = Color(0xFFD1D5DB);
  static const accentDark = Color(0xFF374151);       // close buttons, strong icon

  // ── Cards ────────────────────────────────────────────────────
  static const cardBackground = Color(0xFFFFFFFF);
  static const cardBorder = Color(0xFFF0F1F3);
}

/// Standardized spacing scale (4-point grid).
class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
}

/// Standardized border radius tokens.
class AppRadius {
  AppRadius._();

  static const double sm = 8;   // controls, buttons, inputs
  static const double md = 12;  // cards, panels
  static const double lg = 16;  // dialogs, overlays, drawers
}

/// Standardized animation durations.
class AppDurations {
  AppDurations._();

  static const fast = Duration(milliseconds: 120);    // micro-feedback (hover, press)
  static const normal = Duration(milliseconds: 180);  // state transitions
  static const slow = Duration(milliseconds: 280);    // layout changes, expand/collapse
}

/// Standardized opacity levels.
class AppOpacity {
  AppOpacity._();

  static const double subtle = 0.05;
  static const double light = 0.12;
  static const double medium = 0.3;
  static const double heavy = 0.6;
}
