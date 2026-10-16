import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import 'theme.dart';
import 'widgets.dart';

/// Glass pill with a dropdown that switches the active playlist.
class SourcePicker extends ConsumerWidget {
  const SourcePicker({super.key, this.maxWidth});

  /// Caps the pill on narrow screens; long names are ellipsized.
  final double? maxWidth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).value ?? const [];
    final source = ref.watch(activeSourceProvider);
    final picker = GlassPill(
      leading: Icons.playlist_play_rounded,
      child: DropdownButton<int>(
        value: source?.id,
        isExpanded: maxWidth != null,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        icon: const Icon(Icons.expand_more_rounded, color: AppColors.textDim),
        style: const TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w600),
        items: [
          for (final s in sources)
            DropdownMenuItem(
                value: s.id, child: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) =>
            ref.read(settingsProvider.notifier).update((s) => s.copyWith(activeSourceId: id)),
      ),
    );
    if (maxWidth == null) return picker;
    return ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth!), child: picker);
  }
}
