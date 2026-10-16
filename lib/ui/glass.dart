import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:glass_kit/glass_kit.dart';

import 'theme.dart';

/// Building blocks of the CAT design system: an ambient backdrop, frosted
/// panels, glass tiles and buttons, and the shared entrance motion.

/// Blurred colour fields behind every screen. [hero] (Home) lets them drift
/// and lifts the scrim; other screens get a calmer, darker version so dense
/// content stays readable.
class AppBackdrop extends StatelessWidget {
  const AppBackdrop({super.key, this.hero = false, this.child});
  final bool hero;
  final Widget? child;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: AppColors.bg),
        LayoutBuilder(builder: (context, c) {
          final w = c.maxWidth, h = c.maxHeight;
          // Positions follow the 1440×810 launcher mock-up, scaled.
          final unit = math.max(w / 1440, h / 810);
          Widget glow(double x, double y, double size, Color color, double opacity,
              {required Offset drift, required Duration period}) {
            Widget dot = Container(
              width: size * unit,
              height: size * unit,
              decoration:
                  BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: opacity)),
            );
            if (hero) {
              dot = dot
                  .animate(onPlay: (ctl) => ctl.repeat(reverse: true))
                  .move(begin: Offset.zero, end: drift, duration: period, curve: Curves.easeInOutSine)
                  .scaleXY(begin: 1, end: 1.12, duration: period, curve: Curves.easeInOutSine);
            }
            return Positioned(left: w * x, top: h * y, child: dot);
          }

          return RepaintBoundary(
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 70, sigmaY: 70, tileMode: TileMode.decal),
              child: Stack(children: [
                glow(0.44, -0.15, 620, AppColors.glowBlue, 0.7,
                    drift: const Offset(-40, 30), period: 14.seconds),
                glow(0.71, 0.37, 520, AppColors.glowCyan, 0.45,
                    drift: const Offset(30, -40), period: 17.seconds),
                glow(0.29, 0.52, 480, AppColors.glowIndigo, 0.6,
                    drift: const Offset(50, -20), period: 20.seconds),
              ]),
            ),
          );
        }),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              Color(0xF0080C16),
              Color(0xB8080C16),
              Color(0x40080C16),
            ], stops: [0, 0.45, 1]),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xD9080C16), Color(0x00080C16)],
              stops: [0, 0.4],
            ),
          ),
        ),
        IgnorePointer(
          child: AnimatedOpacity(
            opacity: hero ? 0 : 1,
            duration: AppMotion.slow,
            curve: AppMotion.curve,
            child: const ColoredBox(color: Color(0x66080C16)),
          ),
        ),
        ?child,
      ]);
}

/// A frosted panel with a real backdrop blur, for fixed-size regions such as
/// side columns, the navigation rail and preview areas. Needs bounded size.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = AppRadii.panel,
    this.padding,
    this.margin,
    this.strong = false,
    this.blur = 24,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final bool strong;
  final double blur;

  @override
  Widget build(BuildContext context) => GlassContainer(
        blur: blur,
        margin: margin,
        padding: padding,
        borderRadius: BorderRadius.circular(radius),
        color: strong ? AppColors.glassStrong : AppColors.surface,
        borderColor: strong ? AppColors.glassBorderStrong : AppColors.glassBorder,
        child: Material(type: MaterialType.transparency, child: child),
      );
}

/// Light glass tile for list and grid rows: no backdrop blur (cheap enough
/// for thousands of rows), brightens on hover and when [selected].
class GlassTile extends StatefulWidget {
  const GlassTile({
    super.key,
    required this.child,
    this.selected = false,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapUp,
    this.radius = AppRadii.tile,
    this.padding,
  });

  final Widget child;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapUpCallback? onSecondaryTapUp;
  final double radius;
  final EdgeInsetsGeometry? padding;

  @override
  State<GlassTile> createState() => _GlassTileState();
}

class _GlassTileState extends State<GlassTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final sel = widget.selected;
    final radius = BorderRadius.circular(widget.radius);
    return AnimatedContainer(
      duration: AppMotion.fast,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: sel
            ? AppColors.glassStrong
            : _hover
                ? const Color(0x1AFFFFFF)
                : AppColors.surfaceHigh,
        border: Border.all(
            color: sel ? AppColors.glassBorderStrong : AppColors.glassBorder),
        boxShadow: sel
            ? const [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, 12))]
            : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onTap,
          onDoubleTap: widget.onDoubleTap,
          onSecondaryTapUp: widget.onSecondaryTapUp,
          onHover: (v) => setState(() => _hover = v),
          child: widget.padding == null
              ? widget.child
              : Padding(padding: widget.padding!, child: widget.child),
        ),
      ),
    );
  }
}

/// Round frosted icon button; `selected` brightens the glass and turns the
/// icon amber.
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.size = 48,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: GlassContainer(
          height: size,
          width: size,
          shape: BoxShape.circle,
          blur: 16,
          color: selected ? AppColors.glassStrong : AppColors.glass,
          borderColor: selected ? AppColors.glassBorderStrong : AppColors.glassBorder,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Icon(icon,
                  size: size * 0.44,
                  semanticLabel: tooltip,
                  color: selected ? AppColors.accentBright : AppColors.text),
            ),
          ),
        ),
      );
}

/// Pill-shaped glass search field that reports its text after a short
/// pause in typing. Esc clears it.
class GlassSearchField extends StatefulWidget {
  const GlassSearchField({super.key, required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  State<GlassSearchField> createState() => _GlassSearchFieldState();
}

class _GlassSearchFieldState extends State<GlassSearchField> {
  final _controller = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _changed(String v) {
    setState(() {}); // toggles the clear button
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => widget.onChanged(v.trim()));
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    setState(() {});
    widget.onChanged('');
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): _clear},
        child: TextField(
          controller: _controller,
          onChanged: _changed,
          style: const TextStyle(fontSize: 14),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: widget.hint,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
            prefixIconConstraints: _iconBox,
            suffixIconConstraints: _iconBox,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            suffixIcon: _controller.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: _clear,
                  ),
            border: _pill,
            enabledBorder: _pill,
            focusedBorder: _pill.copyWith(
                borderSide: const BorderSide(color: AppColors.glassBorderStrong, width: 1.2)),
          ),
        ),
      );

  static const _iconBox =
      BoxConstraints.tightFor(width: AppSizes.control, height: AppSizes.control);

  static final _pill = OutlineInputBorder(
    borderRadius: BorderRadius.circular(999),
    borderSide: const BorderSide(color: AppColors.glassBorder),
  );
}

/// A glass pill of control height holding an icon, label or picker.
class GlassPill extends StatelessWidget {
  const GlassPill({super.key, required this.child, this.leading});
  final Widget child;
  final IconData? leading;

  @override
  Widget build(BuildContext context) => Container(
        height: AppSizes.control,
        padding: EdgeInsets.only(left: leading == null ? 16 : 12, right: 8),
        decoration: BoxDecoration(
          color: AppColors.glass,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: AppColors.glassBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (leading != null) ...[
            Icon(leading, size: 20, color: AppColors.textDim),
            const SizedBox(width: 8),
          ],
          DropdownButtonHideUnderline(child: child),
        ]),
      );
}

/// The glowing bar beneath the focused launcher card.
class FocusGlowBar extends StatelessWidget {
  const FocusGlowBar({super.key, required this.active, this.length = 56});
  final bool active;
  final double length;

  @override
  Widget build(BuildContext context) => Container(
        width: length,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(2),
          boxShadow: [
            BoxShadow(color: Colors.white.withValues(alpha: 0.55), blurRadius: 22, spreadRadius: 5),
          ],
        ),
      )
          .animate(target: active ? 1 : 0)
          .fade(begin: 0, end: 1, duration: 220.ms)
          .scale(
            begin: const Offset(0.3, 1),
            end: const Offset(1, 1),
            duration: AppMotion.base,
            curve: Curves.easeOutBack,
          );
}

/// Screen title: a small dim eyebrow over a large display line.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.eyebrow, this.trailing});
  final String title;
  final String? eyebrow;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (eyebrow != null)
                Text(eyebrow!,
                    style: const TextStyle(
                        color: AppColors.textDim, fontSize: 14, fontWeight: FontWeight.w600)),
              if (eyebrow != null) const SizedBox(height: 4),
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                      height: 1.15)),
            ]),
          ),
          ?trailing,
        ],
      ).enter();
}

extension AppEnter on Widget {
  /// The shared entrance: fade in and rise slightly, staggered by [index].
  /// Use on static sections, not on rows of lazily built lists.
  Widget enter([int index = 0]) => animate(delay: AppMotion.stagger * index)
      .fadeIn(duration: AppMotion.slow, curve: AppMotion.curve)
      .slideY(begin: 0.06, end: 0, duration: AppMotion.slow, curve: AppMotion.curve);
}
