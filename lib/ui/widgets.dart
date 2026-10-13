import 'package:flutter/material.dart';

import '../core/image_cache.dart';
import 'theme.dart';

/// Channel logo / poster with disk cache and an initials fallback.
class NetLogo extends StatelessWidget {
  const NetLogo({
    super.key,
    required this.url,
    required this.name,
    this.width = 40,
    this.height = 40,
    this.radius = 10,
    this.fit = BoxFit.contain,
  });

  final String? url;
  final String name;
  final double width;
  final double height;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final fallback = _Initials(name: name, width: width, height: height);
    final u = url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: (u == null || u.isEmpty)
            ? fallback
            : Image(
                image: ResizeImage(
                  CachedNetImage(u),
                  width: (width * dpr).round(),
                  policy: ResizeImagePolicy.fit,
                ),
                fit: fit,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) => fallback,
                frameBuilder: (context, child, frame, sync) =>
                    frame == null && !sync ? fallback : child,
              ),
      ),
    );
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.width, required this.height});
  final String name;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final words = name
        .replaceAll(RegExp(r'^[A-Z]{2,3}\s*[:|\-]\s*'), '')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final initials = words.take(2).map((w) => w.characters.first.toUpperCase()).join();
    final hue = (name.hashCode % 360).abs().toDouble();
    return Container(
      width: width,
      height: height,
      color: HSLColor.fromAHSL(1, hue, 0.18, 0.31).toColor(),
      alignment: Alignment.center,
      child: Text(
        initials.isEmpty ? '?' : initials,
        style: TextStyle(
          fontSize: (height < width ? height : width) * 0.36,
          fontWeight: FontWeight.w700,
          color: AppColors.text,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppColors.textDim),
            const SizedBox(height: 16),
            Text(title, style: t.titleMedium, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(message!,
                    style: t.bodyMedium?.copyWith(color: AppColors.textDim),
                    textAlign: TextAlign.center),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.live,
          borderRadius: BorderRadius.circular(5),
        ),
        child: const Text('Live',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
      );
}

/// Small light tag (HD, EPG, 4K…) used on channel cards.
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: const Color(0xFFD9DAE0),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(text,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: AppColors.bg)),
      );
}

/// Circular glass icon button; `selected` fills it light with a dark icon.
class RoundIconButton extends StatelessWidget {
  const RoundIconButton({
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
        child: Material(
          color: selected ? AppColors.text : AppColors.glass,
          shape: CircleBorder(
              side: BorderSide(color: selected ? Colors.transparent : AppColors.glassBorder)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon,
                  size: size * 0.44, color: selected ? AppColors.bg : AppColors.text),
            ),
          ),
        ),
      );
}

/// Section header used on Home and details pages.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
        child: Row(
          children: [
            Text(text,
                style: Theme.of(context)
                    .textTheme
                    .titleLarge
                    ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2)),
            const Spacer(),
            ?trailing,
          ],
        ),
      );
}

String two(int v) => v.toString().padLeft(2, '0');

String hhmm(DateTime t) => '${two(t.hour)}:${two(t.minute)}';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String formatRelative(DateTime? t) {
  if (t == null) return 'never';
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String formatCount(int n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 10000) return '${(n / 1000).toStringAsFixed(0)}k';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
  return '$n';
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text('$e'),
    backgroundColor: AppColors.live,
    behavior: SnackBarBehavior.floating,
  ));
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(msg),
    behavior: SnackBarBehavior.floating,
    duration: const Duration(seconds: 2),
  ));
}
