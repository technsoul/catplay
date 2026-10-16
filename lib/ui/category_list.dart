import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart';

@immutable
class CategorySelection {
  const CategorySelection.all()
      : categoryId = null,
        favorites = false,
        name = null;
  const CategorySelection.favorites()
      : categoryId = null,
        favorites = true,
        name = null;
  const CategorySelection.category(int this.categoryId, [this.name]) : favorites = false;

  final int? categoryId;
  final bool favorites;

  /// Display name of the category (not part of equality).
  final String? name;

  String get label => favorites ? 'Favorites' : categoryId == null ? 'All categories' : name ?? 'Category';

  @override
  bool operator ==(Object other) =>
      other is CategorySelection &&
      other.categoryId == categoryId &&
      other.favorites == favorites;

  @override
  int get hashCode => Object.hash(categoryId, favorites);
}

/// Left-hand category column for Live / Movies / Series.
class CategoryList extends ConsumerStatefulWidget {
  const CategoryList({
    super.key,
    required this.source,
    required this.kind,
    required this.selection,
    required this.onSelect,
    this.panel = true,
  });

  final Source source;
  final ItemKind kind;
  final CategorySelection selection;
  final ValueChanged<CategorySelection> onSelect;

  /// Draw inside a glass side panel (wide layout) or bare (bottom sheet).
  final bool panel;

  @override
  ConsumerState<CategoryList> createState() => _CategoryListState();
}

class _CategoryListState extends ConsumerState<CategoryList> {
  List<Category>? _cats;
  String _filter = '';
  StreamSubscription? _changes;

  @override
  void initState() {
    super.initState();
    _load();
    _changes = ref.read(databaseProvider).changes.listen((t) {
      if (t.contains('items')) _load();
    });
  }

  @override
  void didUpdateWidget(CategoryList old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id || old.kind != widget.kind) _load();
  }

  @override
  void dispose() {
    _changes?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final cats = await ref.read(repositoryProvider).categories(widget.source.id, widget.kind);
    if (mounted) setState(() => _cats = cats);
  }

  int get _total => switch (widget.kind) {
        ItemKind.live => widget.source.liveCount,
        ItemKind.movie => widget.source.movieCount,
        ItemKind.series => widget.source.seriesCount,
      };

  @override
  Widget build(BuildContext context) {
    final cats = _cats;
    final f = _filter.toLowerCase();
    final visible = cats == null
        ? const <Category>[]
        : (f.isEmpty ? cats : cats.where((c) => c.name.toLowerCase().contains(f)).toList());
    final list = Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: GlassSearchField(
              hint: 'Filter categories',
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          _tile(
            icon: Icons.apps,
            label: 'All',
            count: _total,
            selected: widget.selection == const CategorySelection.all(),
            onTap: () => widget.onSelect(const CategorySelection.all()),
          ),
          _tile(
            icon: Icons.star_outline,
            label: 'Favorites',
            selected: widget.selection.favorites,
            onTap: () => widget.onSelect(const CategorySelection.favorites()),
          ),
          const Divider(height: 12),
          Expanded(
            child: cats == null
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: visible.length,
                    itemExtent: 40,
                    itemBuilder: (_, i) {
                      final c = visible[i];
                      return _tile(
                        label: c.name,
                        count: c.itemCount,
                        selected: widget.selection.categoryId == c.id,
                        onTap: () => widget.onSelect(CategorySelection.category(c.id, c.name)),
                      );
                    },
                  ),
          ),
        ],
    );
    if (!widget.panel) return list;
    return GlassPanel(margin: const EdgeInsets.fromLTRB(12, 4, 8, 16), child: list);
  }

  Widget _tile({
    IconData? icon,
    required String label,
    int? count,
    required bool selected,
    required VoidCallback onTap,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: ListTile(
          dense: true,
          visualDensity: const VisualDensity(vertical: -2),
          selected: selected,
          titleTextStyle: TextStyle(
              fontSize: 14,
              color: selected ? AppColors.text : AppColors.textSoft,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400),
          leading: icon == null ? null : Icon(icon, size: 18),
          minLeadingWidth: 20,
          title: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: count == null
              ? null
              : Text(formatCount(count),
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
          onTap: onTap,
        ),
      );
}

/// Compact layout: a pill naming the current category that opens the
/// category list in a bottom sheet.
class CategoryButton extends StatelessWidget {
  const CategoryButton({
    super.key,
    required this.source,
    required this.kind,
    required this.selection,
    required this.onSelect,
  });

  final Source source;
  final ItemKind kind;
  final CategorySelection selection;
  final ValueChanged<CategorySelection> onSelect;

  Future<void> _open(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: AppColors.sheet,
        builder: (ctx) {
          final size = MediaQuery.sizeOf(ctx);
          final keyboard = MediaQuery.viewInsetsOf(ctx).bottom;
          return Padding(
            padding: EdgeInsets.only(bottom: keyboard),
            child: SizedBox(
              height: math.max(200, math.min(size.height * 0.75, size.height - keyboard - 80)),
              child: CategoryList(
                source: source,
                kind: kind,
                selection: selection,
                panel: false,
                onSelect: (c) {
                  Navigator.pop(ctx);
                  onSelect(c);
                },
              ),
            ),
          );
        },
      );

  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.glass,
        shape: const StadiumBorder(side: BorderSide(color: AppColors.glassBorder)),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => _open(context),
          child: SizedBox(
            height: AppSizes.control,
            child: Row(children: [
              const SizedBox(width: 12),
              Icon(selection.favorites ? Icons.star_rounded : Icons.category_outlined,
                  size: 18, color: selection.favorites ? AppColors.star : AppColors.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: Text(selection.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              const Icon(Icons.expand_more_rounded, color: AppColors.textDim),
              const SizedBox(width: 8),
            ]),
          ),
        ),
      );
}
