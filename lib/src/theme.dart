import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;

/// Local, host-owned branding. No remote styles or downloaded fonts.
///
/// Colours and type sizes follow the website live chat frame.
abstract final class ChatTheme {
  /// Protodesk's primary colour, the web widget's default `#00A5D1`.
  static const protodeskPrimary = Color(0xff00a5d1);

  /// The same bundled variable face as the website, including italic and bold.
  static const websiteFont = 'packages/protodesk_chat/Inter';

  // Android Chrome resolves the widget iframe's CSS system stack to Roboto.
  // The iframe does not inherit the website document's downloaded Inter face.
  static String get defaultFont =>
      defaultTargetPlatform == TargetPlatform.android ? 'Roboto' : websiteFont;

  /// Muted controls in the website frame; high contrast uses the readable role.
  static Color faint(ThemeData theme) =>
      theme.materialTapTargetSize == MaterialTapTargetSize.padded
      ? theme.colorScheme.onSurfaceVariant
      : theme.brightness == Brightness.dark
      ? const Color(0xff71717a)
      : const Color(0xffa1a1aa);

  static ThemeData light({
    Color brandColor = protodeskPrimary,
    String? fontFamily,
    TextTheme? textTheme,
  }) => _build(Brightness.light, brandColor, fontFamily, textTheme);
  static ThemeData dark({
    Color brandColor = protodeskPrimary,
    String? fontFamily,
    TextTheme? textTheme,
  }) => _build(Brightness.dark, brandColor, fontFamily, textTheme);

  /// Preserve branding while preventing dense host controls from shrinking taps.
  static ThemeData accessible(ThemeData theme) {
    ButtonStyle protect(ButtonStyle? style) =>
        (style ?? const ButtonStyle()).copyWith(
          minimumSize: WidgetStateProperty.resolveWith((states) {
            final size =
                style?.minimumSize?.resolve(states) ?? const Size(48, 48);
            return Size(
              size.width < 48 ? 48 : size.width,
              size.height < 48 ? 48 : size.height,
            );
          }),
          fixedSize: const WidgetStatePropertyAll<Size?>(null),
          maximumSize: const WidgetStatePropertyAll(Size.infinite),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.padded,
        );
    final primary = theme.colorScheme.primary;
    return theme.copyWith(
      navigationBarTheme: theme.navigationBarTheme.copyWith(
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => theme.navigationBarTheme.labelTextStyle
              ?.resolve(states)
              ?.copyWith(
                color: states.contains(WidgetState.selected)
                    ? theme.colorScheme.onSurface
                    : theme.colorScheme.onSurfaceVariant,
              ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => theme.navigationBarTheme.iconTheme
              ?.resolve(states)
              ?.copyWith(
                color: states.contains(WidgetState.selected)
                    ? primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
        ),
      ),
      colorScheme: theme.colorScheme.copyWith(
        onPrimary:
            _contrast(primary, Colors.white) >= _contrast(primary, Colors.black)
            ? Colors.white
            : Colors.black,
      ),
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      iconButtonTheme: IconButtonThemeData(
        style: protect(theme.iconButtonTheme.style),
      ),
      textButtonTheme: TextButtonThemeData(
        style: protect(theme.textButtonTheme.style),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: protect(theme.filledButtonTheme.style),
      ),
    );
  }

  static ThemeData _build(
    Brightness brightness,
    Color seed,
    String? font,
    TextTheme? text,
  ) {
    final dark = brightness == Brightness.dark;
    final n = dark ? _Neutrals.dark : _Neutrals.light;
    final brand = seed.withAlpha(0xff);
    final action = ChatBrandColors.readable(brand, n.surface, dark).foreground;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: brand,
      onPrimary: Colors.white,
      primaryContainer: Color.alphaBlend(
        brand.withValues(alpha: dark ? 0.18 : 0.08),
        n.surface,
      ),
      onPrimaryContainer: action,
      secondary: n.secondary,
      onSecondary: dark ? _Zinc.z950 : Colors.white,
      secondaryContainer: n.surfaceMuted,
      onSecondaryContainer: dark ? const Color(0xffd4d4d8) : _Zinc.z800,
      tertiary: n.warning,
      onTertiary: dark ? _Zinc.z950 : Colors.white,
      tertiaryContainer: n.warningSurface,
      onTertiaryContainer: n.warning,
      error: dark ? const Color(0xfff87171) : const Color(0xffdc2626),
      onError: Colors.white,
      errorContainer: dark ? const Color(0xff321719) : const Color(0xfffef2f2),
      onErrorContainer: dark
          ? const Color(0xfffca5a5)
          : const Color(0xffdc2626),
      surface: n.surface,
      onSurface: dark ? _Zinc.z100 : _Zinc.z900,
      onSurfaceVariant: dark ? _Zinc.z400 : const Color(0xff71717a),
      surfaceContainerLowest: n.canvas,
      surfaceContainerLow: n.surfaceRaised,
      surfaceContainer: n.surfaceMuted,
      surfaceContainerHigh: n.surfaceMuted,
      surfaceContainerHighest: dark ? _Zinc.z800 : _Zinc.z200,
      // Control edges need 3:1; the hairlines below are decorative.
      outline: const Color(0xff71717a),
      outlineVariant: n.border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? _Zinc.z100 : _Zinc.z900,
      onInverseSurface: dark ? _Zinc.z900 : _Zinc.z100,
      inversePrimary: action,
      surfaceTint: Colors.transparent,
    );
    final base = ThemeData(
      brightness: brightness,
      useMaterial3: true,
      fontFamily: font ?? defaultFont,
    ).textTheme.merge(text);
    final type = base.copyWith(
      headlineMedium: base.headlineMedium?.copyWith(
        fontSize: 26,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.7,
      ),
      headlineSmall: base.headlineSmall?.copyWith(
        fontSize: 22,
        height: 1.2,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.35,
      ),
      titleLarge: base.titleLarge?.copyWith(
        fontSize: 18,
        height: 1.25,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.15,
      ),
      titleMedium: base.titleMedium?.copyWith(
        fontSize: 14,
        letterSpacing: 0,
        height: 1.3,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: base.titleSmall?.copyWith(
        fontSize: 13,
        height: 1.35,
        letterSpacing: 0,
      ),
      bodyLarge: base.bodyLarge?.copyWith(
        fontSize: 15,
        letterSpacing: 0,
        height: 1.5,
      ),
      bodyMedium: base.bodyMedium?.copyWith(
        fontSize: 13,
        height: 1.48,
        letterSpacing: 0,
      ),
      bodySmall: base.bodySmall?.copyWith(
        fontSize: 11,
        height: 1.45,
        letterSpacing: 0,
      ),
      labelLarge: base.labelLarge?.copyWith(
        inherit: false,
        fontSize: 14,
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: base.labelMedium?.copyWith(
        fontSize: 12,
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
      ),
      labelSmall: base.labelSmall?.copyWith(
        fontSize: 11,
        letterSpacing: 0,
        fontWeight: FontWeight.w500,
      ),
    );
    WidgetStateProperty<Color?> selected(Color fallback) =>
        WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? null
              : states.contains(WidgetState.selected)
              ? action
              : fallback,
        );
    const small = 8.0, medium = 12.0, large = 16.0;
    return ThemeData(
      useMaterial3: true,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: font ?? defaultFont,
      textTheme: type,
      extensions: [
        ChatBrandColors(foreground: action, borderStrong: n.borderStrong),
      ],
      scaffoldBackgroundColor: n.canvas,
      canvasColor: n.canvas,
      dividerColor: n.border,
      appBarTheme: AppBarTheme(
        backgroundColor: n.canvas,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        scrolledUnderElevation: 0,
        titleTextStyle: type.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: n.surface,
        indicatorColor: Colors.transparent,
        height: 68,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final on = states.contains(WidgetState.selected);
          return type.labelSmall?.copyWith(
            fontSize: 10,
            letterSpacing: 0,
            height: 1.1,
            color: on
                ? scheme.onSurface
                : dark
                ? const Color(0xff71717a)
                : const Color(0xffa1a1aa),
            fontWeight: FontWeight.w600,
            fontVariations: const [FontVariation.weight(650)],
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final on = states.contains(WidgetState.selected);
          return IconThemeData(
            size: 21,
            color: on
                ? brand
                : dark
                ? const Color(0xff71717a)
                : const Color(0xffa1a1aa),
          );
        }),
      ),
      listTileTheme: ListTileThemeData(
        minVerticalPadding: 8,
        minLeadingWidth: 24,
        horizontalTitleGap: 12,
        titleTextStyle: type.titleMedium?.copyWith(color: scheme.onSurface),
        subtitleTextStyle: type.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(color: n.border, thickness: 1, space: 1),
      dialogTheme: DialogThemeData(
        backgroundColor: n.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(large),
        ),
        titleTextStyle: type.titleLarge?.copyWith(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: n.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(large),
          side: BorderSide(color: n.border),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: n.surface,
        alignLabelWithHint: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        hintStyle: type.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        labelStyle: type.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        floatingLabelStyle: WidgetStateTextStyle.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.error)
                ? scheme.error
                : states.contains(WidgetState.focused)
                ? action
                : scheme.onSurfaceVariant,
          ),
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(medium)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(medium),
          borderSide: BorderSide(color: n.borderStrong),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(medium),
          borderSide: BorderSide(color: action, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(medium),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(medium),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 40),
          foregroundColor: action,
          textStyle: type.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(medium),
          ),
          textStyle: type.labelLarge?.copyWith(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: n.borderStrong),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(medium),
          ),
          textStyle: type.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size.square(36),
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
          foregroundColor: scheme.onSurfaceVariant,
          highlightColor: brand.withValues(alpha: 0.08),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: action,
        selectionColor: brand.withValues(alpha: 0.2),
        selectionHandleColor: action,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: n.surface,
        surfaceTintColor: Colors.transparent,
        textStyle: type.bodyMedium?.copyWith(color: scheme.onSurface),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(medium),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(n.surface),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(medium)),
          ),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: n.surfaceMuted,
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(small),
        ),
        labelStyle: type.labelSmall,
        padding: const EdgeInsets.symmetric(horizontal: 6),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: brand),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: n.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(large)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(medium),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: selected(Colors.transparent),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
      radioTheme: RadioThemeData(fillColor: selected(scheme.onSurfaceVariant)),
    );
  }
}

/// Zinc scale shared with the Protodesk mobile app.
abstract final class _Zinc {
  static const z950 = Color(0xff111113);
  static const z900 = Color(0xff18181b);
  static const z800 = Color(0xff27272a);
  static const z600 = Color(0xff52525b);
  static const z400 = Color(0xffa1a1aa);
  static const z200 = Color(0xffe4e4e7);
  static const z100 = Color(0xfff4f4f5);
}

/// The mobile app's `ProtodeskColors` neutrals for one brightness.
class _Neutrals {
  const _Neutrals({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceRaised,
    required this.border,
    required this.borderStrong,
    required this.secondary,
    required this.warning,
    required this.warningSurface,
  });
  final Color canvas, surface, surfaceMuted, surfaceRaised;
  final Color border, borderStrong, secondary, warning, warningSurface;

  static const light = _Neutrals(
    canvas: Color(0xffffffff),
    surface: Color(0xffffffff),
    surfaceMuted: _Zinc.z100,
    surfaceRaised: Color(0xfffafafa),
    border: _Zinc.z200,
    borderStrong: Color(0xffd4d4d8),
    secondary: _Zinc.z600,
    warning: Color(0xffb45309),
    warningSurface: Color(0xfffffbeb),
  );
  static const dark = _Neutrals(
    canvas: Color(0xff111217),
    surface: Color(0xff15161b),
    surfaceMuted: Color(0xff222329),
    surfaceRaised: Color(0xff1a1b20),
    border: Color(0xff2c2e35),
    borderStrong: Color(0xff3a3c44),
    secondary: _Zinc.z400,
    warning: Color(0xfffbbf24),
    warningSurface: Color(0xff2a2112),
  );
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (x > y ? x + 0.05 : y + 0.05) / (x > y ? y + 0.05 : x + 0.05);
}

/// Brand colours for text, links, icons and focus rings on surfaces. The brand
/// fills buttons as-is, but a bright brand is too light for text on white, so
/// [foreground] is the brand darkened (or, in dark mode, lightened) just
/// enough for 4.5:1 contrast on the surface, like the mobile app's
/// `accentInk`/`accentLight`.
@immutable
class ChatBrandColors extends ThemeExtension<ChatBrandColors> {
  const ChatBrandColors({required this.foreground, Color? borderStrong})
    : borderStrong = borderStrong ?? const Color(0x1f000000);

  /// Derives a readable foreground for [brand] on [surface].
  factory ChatBrandColors.readable(Color brand, Color surface, bool dark) {
    final target = dark ? Colors.white : Colors.black;
    var color = brand;
    for (var step = 1; step <= 50 && _contrast(color, surface) < 4.5; step++) {
      color = Color.lerp(brand, target, step / 50)!;
    }
    return ChatBrandColors(foreground: color);
  }

  final Color foreground;

  /// The mobile app's stronger hairline, for surfaces such as the composer.
  final Color borderStrong;

  /// The theme's brand colours; host themes without them fall back to
  /// Material's `primary`, which already meets text contrast.
  static ChatBrandColors resolve(ThemeData theme) =>
      theme.extension<ChatBrandColors>() ??
      ChatBrandColors(
        foreground: theme.colorScheme.primary,
        borderStrong: theme.colorScheme.outlineVariant,
      );

  @override
  ChatBrandColors copyWith({Color? foreground, Color? borderStrong}) =>
      ChatBrandColors(
        foreground: foreground ?? this.foreground,
        borderStrong: borderStrong ?? this.borderStrong,
      );

  @override
  ChatBrandColors lerp(ChatBrandColors? other, double t) => other == null
      ? this
      : ChatBrandColors(
          foreground: Color.lerp(foreground, other.foreground, t)!,
          borderStrong: Color.lerp(borderStrong, other.borderStrong, t),
        );
}
