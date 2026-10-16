import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../data/repository.dart';
import '../../ui/category_list.dart';
import '../../ui/paged_items.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'details.dart';

/// Poster grid browser for Movies and Series.
class VodPage extends ConsumerStatefulWidget {
  const VodPage({super.key, required this.source, required this.kind});
  final Source source;
  final ItemKind kind;

  @override
  ConsumerState<VodPage> createState() => _VodPageState();
}

class _VodPageState extends ConsumerState<VodPage> {
  CategorySelection _cat = const CategorySelection.all();
  ItemSort _sort = ItemSort.playlist;
  PagedItems? _items;
  StreamSubscription? _changes;
  final _scroll = ScrollController();
  String _text = '';

  Repository get _repo => ref.read(repositoryProvider);

  ItemQuery get _query => ItemQuery(
        kind: widget.kind,
        sourceId: widget.source.id,
        categoryId: _cat.categoryId,
        favoritesOnly: _cat.favorites,
        sort: _sort,
        text: _text,
      );

  @override
  void initState() {
    super.initState();
    _rebuild();
    _changes = ref.read(databaseProvider).changes.listen((t) {
      if (t.contains('items') || t.contains('favorites')) _items?.refresh();
    });
  }

  @override
  void didUpdateWidget(VodPage old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id || old.kind != widget.kind) {
      _cat = const CategorySelection.all();
      _rebuild();
    }
  }

  void _rebuild() {
    _items?.dispose();
    _items = PagedItems(_repo, _query, pageSize: 120)..addListener(() => setState(() {}));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  void dispose() {
    _changes?.cancel();
    _items?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 250,
          child: CategoryList(
            source: widget.source,
            kind: widget.kind,
            selection: _cat,
            onSelect: (c) {
              setState(() => _cat = c);
              _rebuild();
            },
          ),
        ),
        Expanded(
          child: Column(
            children: [
              _toolbar(),
              Expanded(child: _grid()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _toolbar() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 24, 4),
        child: Row(
          children: [
            Expanded(
              child: PageHeader(
                eyebrow: _items?.total == null ? ' ' : '${formatCount(_items!.total!)} titles',
                title: widget.kind == ItemKind.movie ? 'Movies' : 'Series',
              ),
            ),
            SizedBox(
              width: 300,
              child: GlassSearchField(
                key: ValueKey(widget.kind),
                hint: widget.kind == ItemKind.movie ? 'Search movies' : 'Search series',
                onChanged: (v) {
                  setState(() => _text = v);
                  _rebuild();
                },
              ),
            ),
            const SizedBox(width: 12),
            GlassPill(
              leading: Icons.sort_rounded,
              child: DropdownButton<ItemSort>(
                value: _sort,
                borderRadius: BorderRadius.circular(AppRadii.tile),
                icon: const Icon(Icons.expand_more_rounded, color: AppColors.textDim),
                style: const TextStyle(color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w600),
                items: const [
                  DropdownMenuItem(value: ItemSort.playlist, child: Text('Default')),
                  DropdownMenuItem(value: ItemSort.added, child: Text('Recently added')),
                  DropdownMenuItem(value: ItemSort.name, child: Text('Name')),
                  DropdownMenuItem(value: ItemSort.rating, child: Text('Rating')),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _sort = v);
                  _rebuild();
                },
              ),
            ),
          ],
        ),
      );

  Widget _grid() {
    final items = _items!;
    final total = items.total;
    if (total == null) return const Center(child: CircularProgressIndicator());
    if (total == 0 && _text.isNotEmpty) {
      return EmptyState(icon: Icons.search_off, title: 'Nothing matches "$_text"');
    }
    if (total == 0) {
      return EmptyState(
        icon: widget.kind == ItemKind.movie ? Icons.movie_outlined : Icons.video_library_outlined,
        title: _cat.favorites ? 'No favorites yet' : 'Nothing here',
      );
    }
    return Scrollbar(
      controller: _scroll,
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 180,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.56,
        ),
        itemCount: total,
        itemBuilder: (context, i) {
          final item = items.itemAt(i);
          if (item == null) {
            return Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(AppRadii.tile),
              ),
            );
          }
          return PosterCard(
            item: item,
            onTap: () => openDetails(context, ref, item),
          );
        },
      ),
    );
  }
}

class PosterCard extends StatefulWidget {
  const PosterCard({super.key, required this.item, required this.onTap, this.progress});
  final MediaItem item;
  final VoidCallback onTap;
  final double? progress;

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: _hover ? 1.04 : 1,
          duration: AppMotion.fast,
          curve: AppMotion.curve,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (_, c) => Stack(
                    children: [
                      NetLogo(
                        url: item.logo,
                        name: item.name,
                        width: c.maxWidth,
                        height: c.maxHeight,
                        radius: AppRadii.tile,
                        fit: BoxFit.cover,
                      ),
                      if (item.rating != null && item.rating! > 0)
                        Positioned(
                          top: 6,
                          left: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xCC080C16),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              const Icon(Icons.star, size: 11, color: AppColors.star),
                              const SizedBox(width: 2),
                              Text(item.rating!.toStringAsFixed(1),
                                  style: const TextStyle(fontSize: 11)),
                            ]),
                          ),
                        ),
                      if (item.isFavorite)
                        const Positioned(
                          top: 6,
                          right: 6,
                          child: Icon(Icons.star, size: 18, color: AppColors.star),
                        ),
                      // Glass rim and lift on hover, like the launcher cards.
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedContainer(
                            duration: AppMotion.fast,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(AppRadii.tile),
                              border: Border.all(
                                  color: _hover ? AppColors.glassBorderStrong : AppColors.glassBorder),
                              boxShadow: _hover
                                  ? const [
                                      BoxShadow(
                                          color: Color(0x80000000),
                                          blurRadius: 40,
                                          offset: Offset(0, 18)),
                                    ]
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      if (widget.progress != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: widget.progress,
                            minHeight: 3,
                            backgroundColor: Colors.black54,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
              if (item.year != null)
                Text(item.year!, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
            ],
          ),
        ),
      ),
    );
  }
}
