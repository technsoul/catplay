import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/xtream.dart';
import '../../core/models.dart';
import '../../data/repository.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/category_list.dart';
import '../../ui/paged_items.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class LivePage extends ConsumerStatefulWidget {
  const LivePage({super.key, required this.source});
  final Source source;

  @override
  ConsumerState<LivePage> createState() => _LivePageState();
}

class _LivePageState extends ConsumerState<LivePage> {
  CategorySelection _cat = const CategorySelection.all();
  PagedItems? _items;
  final _epg = <String, List<Programme>>{};
  MediaItem? _selected;
  Timer? _epgTimer;
  StreamSubscription? _changes;
  final _scroll = ScrollController();
  String _text = '';
  late final AppPlayer _player;

  Repository get _repo => ref.read(repositoryProvider);

  ItemQuery get _query => ItemQuery(
        kind: ItemKind.live,
        sourceId: widget.source.id,
        categoryId: _cat.categoryId,
        favoritesOnly: _cat.favorites,
        text: _text,
      );

  @override
  void initState() {
    super.initState();
    _rebuildItems();
    _epgTimer = Timer.periodic(const Duration(minutes: 1), (_) => _refreshEpg());
    _player = ref.read(appPlayerProvider)..state.addListener(_followPlayer);
    _changes = ref.read(databaseProvider).changes.listen((t) {
      if (t.contains('items') || (_cat.favorites && t.contains('favorites'))) {
        _items?.refresh();
      }
      if (t.contains('epg')) _refreshEpg();
    });
  }

  @override
  void didUpdateWidget(LivePage old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id) {
      _cat = const CategorySelection.all();
      _selected = null;
      _rebuildItems();
    }
  }

  void _rebuildItems() {
    _items?.dispose();
    _epg.clear();
    final items = PagedItems(_repo, _query);
    items.onPageLoaded = _loadEpgFor;
    items.addListener(() => setState(() {}));
    _items = items;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Keeps the highlighted channel/schedule in sync when the player changes
  /// channel by itself (zapping in full screen, guide, autoplay…).
  Future<void> _followPlayer() async {
    final p = _player.state.value.playable;
    if (p == null || !p.isLive || p.sourceId != widget.source.id) return;
    if (_selected?.key == p.key) return;
    final item = _items?.loadedItems.where((i) => i.key == p.key).firstOrNull ??
        await _repo.itemByKey(p.sourceId, p.key);
    if (!mounted || item == null || _player.state.value.playable?.key != item.key) return;
    setState(() => _selected = item);
    final idx = _items?.indexOf(item);
    if (idx != null && _scroll.hasClients) {
      final pos = _scroll.position;
      final top = idx * 64.0;
      if (top < pos.pixels || top + 64 > pos.pixels + pos.viewportDimension) {
        _scroll.animateTo((top - pos.viewportDimension / 2).clamp(0, pos.maxScrollExtent),
            duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    }
  }

  Future<void> _loadEpgFor(List<MediaItem> page) async {
    final ids = [for (final i in page) if (i.epgId != null) i.epgId!];
    if (ids.isEmpty) return;
    final m = await _repo.nowNext(widget.source.id, ids);
    if (!mounted) return;
    setState(() => _epg.addAll(m));
  }

  Future<void> _refreshEpg() async {
    final loaded = _items?.loadedItems.toList() ?? const [];
    _epg.clear();
    await _loadEpgFor(loaded);
  }

  @override
  void dispose() {
    _epgTimer?.cancel();
    _player.state.removeListener(_followPlayer);
    _changes?.cancel();
    _items?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _play(MediaItem item, int index) async {
    setState(() => _selected = item);
    final p = await playableFor(_repo, item);
    if (p == null) return;
    await ref.read(appPlayerProvider).open(p, zapQuery: _query, zapIndex: index);
  }

  Future<void> _toggleFav(MediaItem item) async {
    final fav = await _repo.toggleFavorite(item);
    _items?.replace(item.copyWith(isFavorite: fav));
    if (_selected?.id == item.id) setState(() => _selected = item.copyWith(isFavorite: fav));
  }

  void _openFull() => PlayerPage.open(context, stopOnExit: false);

  @override
  Widget build(BuildContext context) {
    final playing = ref.watch(appPlayerProvider).state;
    return Row(
      children: [
        SizedBox(
          width: 250,
          child: CategoryList(
            source: widget.source,
            kind: ItemKind.live,
            selection: _cat,
            onSelect: (c) {
              setState(() => _cat = c);
              _rebuildItems();
            },
          ),
        ),
        SizedBox(
          width: 420,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: GlassSearchField(
                hint: 'Search channels',
                onChanged: (v) {
                  setState(() => _text = v);
                  _rebuildItems();
                },
              ),
            ),
            Expanded(child: _channelList(playing)),
          ]),
        ),
        Expanded(child: _previewPane()),
      ],
    );
  }

  Widget _channelList(ValueNotifier<PlayerUiState> playing) {
    final items = _items!;
    final total = items.total;
    if (total == null) return const Center(child: CircularProgressIndicator());
    if (total == 0 && _text.isNotEmpty) {
      return EmptyState(icon: Icons.search_off, title: 'No channels match "$_text"');
    }
    if (total == 0) {
      return EmptyState(
        icon: _cat.favorites ? Icons.star_border : Icons.live_tv,
        title: _cat.favorites ? 'No favorite channels yet' : 'No channels here',
        message: _cat.favorites
            ? 'Right-click a channel or use the star to add it to favorites.'
            : null,
      );
    }
    return ValueListenableBuilder(
      valueListenable: playing,
      builder: (context, ps, _) => Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          itemCount: total,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemExtent: 80,
          itemBuilder: (context, i) {
            final item = items.itemAt(i);
            if (item == null) return const _ChannelSkeleton();
            final isPlaying = ps.playable?.sourceId == item.sourceId &&
                ps.playable?.key == item.key;
            return ChannelTile(
              item: item,
              index: i,
              programmes: item.epgId == null ? null : _epg[item.epgId],
              selected: _selected?.id == item.id,
              playing: isPlaying,
              onTap: () => _play(item, i),
              onDoubleTap: () async {
                if (!isPlaying) await _play(item, i);
                _openFull();
              },
              onFavorite: () => _toggleFav(item),
            );
          },
        ),
      ),
    );
  }

  Widget _previewPane() {
    final sel = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 24, 16),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.panel),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: PlayerView(compact: true, onExpand: _openFull),
            ),
          ),
        ),
        if (sel != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 24, 0),
            child: Row(
              children: [
                NetLogo(url: sel.logo, name: sel.name, width: 64, height: 44),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(sel.name,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: sel.isFavorite ? 'Remove from favorites' : 'Add to favorites',
                  icon: Icon(sel.isFavorite ? Icons.star : Icons.star_border,
                      color: sel.isFavorite ? AppColors.star : null),
                  onPressed: () => _toggleFav(sel),
                ),
                const SizedBox(width: 6),
                FilledButton.icon(
                  onPressed: _openFull,
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('Full screen'),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: sel == null
              ? const SizedBox.shrink()
              : ChannelSchedule(key: ValueKey(sel.id), item: sel),
        ),
      ],
    );
  }
}

class _ChannelSkeleton extends StatelessWidget {
  const _ChannelSkeleton();
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
        child: Row(children: [
          Container(
            width: 64,
            height: 44,
            decoration: BoxDecoration(
                color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(10)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                  color: AppColors.surfaceHigh, borderRadius: BorderRadius.circular(4)),
            ),
          ),
        ]),
      );
}

class ChannelTile extends StatelessWidget {
  const ChannelTile({
    super.key,
    required this.item,
    required this.index,
    required this.programmes,
    required this.selected,
    required this.playing,
    required this.onTap,
    required this.onDoubleTap,
    required this.onFavorite,
  });

  final MediaItem item;
  final int index;
  final List<Programme>? programmes;
  final bool selected;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onFavorite;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final current = programmes?.where((p) => p.isLiveAt(now)).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: GlassTile(
        selected: selected,
        radius: 16,
        onTap: onTap,
        onDoubleTap: onDoubleTap,
        onSecondaryTapUp: (d) => _menu(context, d.globalPosition),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              NetLogo(url: item.logo, name: item.name, width: 76, height: 52),
              const SizedBox(width: 12),
              SizedBox(
                width: 34,
                child: Text(
                  '${item.number ?? index + 1}',
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                ),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      if (playing) ...[
                        const Icon(Icons.graphic_eq, size: 14, color: AppColors.accentBright),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(item.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: playing ? AppColors.accentBright : null)),
                      ),
                    ]),
                    if (current != null) ...[
                      const SizedBox(height: 3),
                      Text(current.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: current.progressAt(now),
                          minHeight: 3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (item.isFavorite)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Icon(Icons.star, size: 18, color: AppColors.star),
                ),
              if (item.catchupDays != null && item.catchupDays! > 0)
                const Padding(
                  padding: EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: 'Catch-up available',
                    child: Icon(Icons.history, size: 16, color: AppColors.textDim),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, Offset pos) async {
    final v = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx, pos.dy),
      items: [
        const PopupMenuItem(value: 'play', child: Text('Play')),
        const PopupMenuItem(value: 'full', child: Text('Play full screen')),
        PopupMenuItem(
            value: 'fav',
            child: Text(item.isFavorite ? 'Remove from favorites' : 'Add to favorites')),
      ],
    );
    switch (v) {
      case 'play':
        onTap();
      case 'full':
        onDoubleTap();
      case 'fav':
        onFavorite();
    }
  }
}

/// Today's programmes for one channel, with catch-up where available.
class ChannelSchedule extends ConsumerStatefulWidget {
  const ChannelSchedule({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<ChannelSchedule> createState() => _ChannelScheduleState();
}

class _ChannelScheduleState extends ConsumerState<ChannelSchedule> {
  List<Programme>? _list;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epg = widget.item.epgId;
    if (epg == null) {
      setState(() => _list = const []);
      return;
    }
    final now = DateTime.now();
    final back = Duration(days: (widget.item.catchupDays ?? 0).clamp(0, 3));
    final list = await ref.read(repositoryProvider).programmes(
          widget.item.sourceId,
          epg,
          now.subtract(back + const Duration(hours: 3)),
          now.add(const Duration(hours: 24)),
        );
    if (!mounted) return;
    setState(() => _list = list);
    // Scroll so the current programme is near the top.
    final idx = list.indexWhere((p) => p.isLiveAt(now));
    if (idx > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(((idx - 1) * 64.0).clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
  }

  Future<void> _catchup(Programme p) async {
    final item = widget.item;
    final api = await ref.read(xtreamApiProvider(item.sourceId).future);
    if (api == null || item.extId == null) return;
    final minutes = p.stop.difference(p.start).inMinutes;
    final url = api.timeshiftUrl(item.extId!, p.start, minutes);
    await ref.read(appPlayerProvider).open(Playable(
          sourceId: item.sourceId,
          key: 'catchup:${item.key}:${p.start.millisecondsSinceEpoch}',
          kind: ItemKind.movie,
          title: p.title,
          subtitle: '${item.name} · ${hhmm(p.start)}',
          url: url,
          logo: item.logo,
        ));
    if (mounted) await PlayerPage.open(context);
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    if (list == null) return const Center(child: CircularProgressIndicator());
    if (list.isEmpty) {
      return const EmptyState(
        icon: Icons.event_busy,
        title: 'No programme information',
        message: 'Add a TV guide (XMLTV) URL to this playlist in Playlists to see the schedule.',
      );
    }
    final now = DateTime.now();
    final canCatchup = (widget.item.catchupDays ?? 0) > 0;
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: list.length,
      itemExtent: 64,
      itemBuilder: (context, i) {
        final p = list[i];
        final live = p.isLiveAt(now);
        final past = p.stop.isBefore(now);
        return ListTile(
          selected: live,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          leading: SizedBox(
            width: 92,
            child: Text('${hhmm(p.start)} – ${hhmm(p.stop)}',
                style: TextStyle(
                    color: past ? AppColors.textDim : null,
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          title: Row(children: [
            if (live) ...[const LiveBadge(), const SizedBox(width: 8)],
            Expanded(
              child: Text(p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: past && !live ? AppColors.textDim : null)),
            ),
          ]),
          subtitle: p.description == null
              ? null
              : Text(p.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: past && canCatchup
              ? IconButton(
                  tooltip: 'Watch from catch-up',
                  icon: const Icon(Icons.replay),
                  onPressed: () => _catchup(p),
                )
              : null,
          onTap: () => showProgrammeDialog(context, p, widget.item.name),
        );
      },
    );
  }
}

Future<void> showProgrammeDialog(BuildContext context, Programme p, String channel) =>
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(p.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$channel · ${hhmm(p.start)} – ${hhmm(p.stop)}'
                '${p.category != null ? ' · ${p.category}' : ''}',
                style: const TextStyle(color: AppColors.textDim),
              ),
              if (p.description != null) ...[
                const SizedBox(height: 12),
                Flexible(child: SingleChildScrollView(child: Text(p.description!))),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
