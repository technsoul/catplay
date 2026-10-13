import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../data/repository.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../vod/details.dart';

/// Continue watching, recent channels and favorites at a glance.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.source, required this.onNavigate});
  final Source source;
  final ValueChanged<int> onNavigate;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  List<HistoryEntry> _continue = const [];
  List<HistoryEntry> _recent = const [];
  List<MediaItem> _favChannels = const [];
  List<MediaItem> _favVod = const [];
  List<MediaItem> _newMovies = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(HomePage old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id) _load();
  }

  Future<void> _load() async {
    final repo = ref.read(repositoryProvider);
    final sid = widget.source.id;
    final results = await Future.wait([
      repo.continueWatching(),
      repo.recentChannels(limit: 12),
      repo.items(ItemQuery(kind: ItemKind.live, sourceId: sid, favoritesOnly: true), limit: 24),
      repo.items(ItemQuery(kind: ItemKind.movie, sourceId: sid, favoritesOnly: true), limit: 24),
      repo.items(ItemQuery(kind: ItemKind.movie, sourceId: sid, sort: ItemSort.added), limit: 24),
    ]);
    if (!mounted) return;
    setState(() {
      _continue = results[0] as List<HistoryEntry>;
      _recent = results[1] as List<HistoryEntry>;
      _favChannels = results[2] as List<MediaItem>;
      _favVod = results[3] as List<MediaItem>;
      _newMovies = results[4] as List<MediaItem>;
    });
  }

  Future<void> _resume(HistoryEntry h) async {
    final repo = ref.read(repositoryProvider);
    await ref.read(appPlayerProvider).open(Playable(
          sourceId: h.sourceId,
          key: h.key,
          kind: h.kind,
          title: h.name,
          url: h.url,
          logo: h.logo,
          resumeFrom: h.kind == ItemKind.live ? null : await repo.resumePosition(h.sourceId, h.key),
        ));
    if (mounted) await PlayerPage.open(context, stopOnExit: h.kind != ItemKind.live);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    // Reload when history/favorites change elsewhere.
    ref.listen(dataVersionProvider('history'), (_, _) => _load());
    ref.listen(dataVersionProvider('favorites'), (_, _) => _load());

    final s = widget.source;
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 32, 32),
      children: [
        Text('Welcome back',
            style: t.displaySmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.5)),
        // Counts live on the cards; only surface the subscription when it needs attention.
        if (s.expiresAt != null && s.expiresAt!.difference(DateTime.now()).inDays < 14) ...[
          const SizedBox(height: 4),
          _Expiry(expiresAt: s.expiresAt!),
        ],
        const SizedBox(height: 28),
        _LauncherRow(cards: [
          _LauncherCard(
              icon: Icons.live_tv,
              label: 'Live TV',
              sub: '${formatCount(s.liveCount)} channels',
              note: 'Updated ${formatRelative(s.lastRefresh)}',
              primary: true,
              onTap: () => widget.onNavigate(1)),
          _LauncherCard(
              icon: Icons.movie_outlined,
              label: 'Movies',
              sub: '${formatCount(s.movieCount)} titles',
              onTap: () => widget.onNavigate(3)),
          _LauncherCard(
              icon: Icons.video_library_outlined,
              label: 'Series',
              sub: '${formatCount(s.seriesCount)} series',
              onTap: () => widget.onNavigate(4)),
          _LauncherCard(
              icon: Icons.calendar_view_week,
              label: 'TV Guide',
              sub: "What's on now",
              onTap: () => widget.onNavigate(2)),
        ]),
        if (_continue.isNotEmpty) ...[
          const SizedBox(height: 28),
          const SectionTitle('Continue watching'),
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _continue.length,
              separatorBuilder: (_, _) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final h = _continue[i];
                return _HistoryCard(
                  entry: h,
                  onTap: () => _resume(h),
                  onRemove: () async {
                    await ref.read(repositoryProvider).removeHistory(h.sourceId, h.key);
                    _load();
                  },
                );
              },
            ),
          ),
        ],
        if (_recent.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionTitle('Recently watched channels'),
          _ChannelRow(
            children: [
              for (final h in _recent)
                _ChannelChip(name: h.name, logo: h.logo, onTap: () => _resume(h)),
            ],
          ),
        ],
        if (_favChannels.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionTitle('Favorite channels'),
          _ChannelRow(
            children: [
              for (final c in _favChannels)
                _ChannelChip(
                  name: c.name,
                  logo: c.logo,
                  onTap: () => openDetails(context, ref, c),
                ),
            ],
          ),
        ],
        if (_favVod.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionTitle('Favorite movies'),
          _PosterRow(items: _favVod),
        ],
        if (_newMovies.isNotEmpty) ...[
          const SizedBox(height: 24),
          const SectionTitle('Recently added movies'),
          _PosterRow(items: _newMovies),
        ],
      ],
    );
  }
}

class _Expiry extends StatelessWidget {
  const _Expiry({required this.expiresAt});
  final DateTime expiresAt;

  @override
  Widget build(BuildContext context) {
    final days = expiresAt.difference(DateTime.now()).inDays;
    final color = days < 0
        ? AppColors.live
        : days < 7
            ? AppColors.warning
            : AppColors.textDim;
    return Text(
      days < 0
          ? 'Subscription expired on ${expiresAt.toLocal().toString().split(' ').first}'
          : 'Subscription expires in $days days',
      style: TextStyle(color: color),
    );
  }
}

/// Lays the launcher cards out to fill the available width: one row on wide
/// screens (the first card larger, others bottom-aligned), a 2×2 grid on
/// medium widths and a single column on narrow ones.
class _LauncherRow extends StatelessWidget {
  const _LauncherRow({required this.cards});
  final List<_LauncherCard> cards;

  static const _gap = 20.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        if (w >= 900) {
          // Primary card gets 1.3 shares, the rest 1 share each.
          final shares = 1.3 + (cards.length - 1);
          final unit = (w - _gap * (cards.length - 1)) / shares;
          final h = (unit * 1.3 * 1.15).clamp(260.0, 560.0);
          return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              Expanded(
                flex: cards[i].primary ? 13 : 10,
                child: SizedBox(height: cards[i].primary ? h : h * 0.85, child: cards[i]),
              ),
            ],
          ]);
        }
        final cols = w >= 520 ? 2 : 1;
        final cw = (w - _gap * (cols - 1)) / cols;
        final h = cols == 1 ? 170.0 : (cw * 0.62).clamp(190.0, 320.0);
        return Wrap(spacing: _gap, runSpacing: _gap, children: [
          for (final card in cards) SizedBox(width: cw, height: h, child: card),
        ]);
      });
}

class _LauncherCard extends StatelessWidget {
  const _LauncherCard({
    required this.icon,
    required this.label,
    required this.sub,
    required this.onTap,
    this.note,
    this.primary = false,
  });
  final IconData icon;
  final String label;
  final String sub;
  final String? note;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: primary ? AppColors.raised : AppColors.surfaceHigh,
        elevation: primary ? 16 : 0,
        shadowColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: primary ? BorderSide.none : const BorderSide(color: AppColors.glassBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: LayoutBuilder(builder: (context, c) {
            // Content scales with the card so it reads well on any screen.
            final k = (c.maxHeight / 300).clamp(0.7, 1.7);
            return Padding(
              padding: EdgeInsets.all(26 * k),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (note != null)
                  Align(
                    alignment: Alignment.topRight,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.refresh, size: 14 * k, color: AppColors.textSoft),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(note!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12 * k, color: AppColors.textSoft)),
                      ),
                    ]),
                  ),
                const Spacer(),
                Icon(icon, size: (primary ? 48 : 40) * k, color: AppColors.text),
                SizedBox(height: 16 * k),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: (primary ? 36 : 30) * k, fontWeight: FontWeight.w600, height: 1.1)),
                SizedBox(height: 2 * k),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15 * k, color: primary ? AppColors.textSoft : AppColors.textDim)),
              ]),
            );
          }),
        ),
      );
}

class _HistoryCard extends StatelessWidget {
  const _HistoryCard({required this.entry, required this.onTap, required this.onRemove});
  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 240,
        child: Card(
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Stack(fit: StackFit.expand, children: [
                  NetLogo(url: entry.logo, name: entry.name, width: 240, height: 100,
                      radius: 0, fit: BoxFit.cover),
                  const Center(child: Icon(Icons.play_circle_fill, size: 44, color: AppColors.text)),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: onRemove,
                    ),
                  ),
                ]),
              ),
              LinearProgressIndicator(value: entry.progress, minHeight: 3),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
        ),
      );
}

class _ChannelRow extends StatelessWidget {
  const _ChannelRow({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 96,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: children.length,
          separatorBuilder: (_, _) => const SizedBox(width: 14),
          itemBuilder: (_, i) => children[i],
        ),
      );
}

class _ChannelChip extends StatelessWidget {
  const _ChannelChip({required this.name, required this.logo, required this.onTap});
  final String name;
  final String? logo;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 120,
        child: Card(
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadii.card),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                NetLogo(url: logo, name: name, width: 64, height: 44),
                const SizedBox(height: 6),
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ),
      );
}

class _PosterRow extends ConsumerWidget {
  const _PosterRow({required this.items});
  final List<MediaItem> items;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        height: 230,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: items.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, i) => SizedBox(
            width: 130,
            child: InkWell(
              onTap: () => openDetails(context, ref, items[i]),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                NetLogo(url: items[i].logo, name: items[i].name, width: 130, height: 190,
                    radius: 14, fit: BoxFit.cover),
                const SizedBox(height: 6),
                Text(items[i].name, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12)),
              ]),
            ),
          ),
        ),
      );
}
