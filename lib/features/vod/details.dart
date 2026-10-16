import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/xtream.dart';
import '../../core/models.dart';
import '../../downloads/download_button.dart';
import '../../downloads/downloads.dart';
import '../../parsers/xtream_api.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Opens the right detail view (or plays directly) for an item.
Future<void> openDetails(BuildContext context, WidgetRef ref, MediaItem item) async {
  switch (item.kind) {
    case ItemKind.live:
      final p = await playableFor(ref.read(repositoryProvider), item);
      if (p == null) return;
      await ref.read(appPlayerProvider).open(p);
      if (context.mounted) await PlayerPage.open(context, stopOnExit: false);
    case ItemKind.movie:
      await showDialog(context: context, builder: (_) => MovieDetails(item: item));
    case ItemKind.series:
      if (item.url != null) {
        // M3U "series" entries are individual episodes with their own URL.
        await showDialog(context: context, builder: (_) => MovieDetails(item: item));
      } else {
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SeriesPage(item: item)));
      }
  }
}

class MovieDetails extends ConsumerStatefulWidget {
  const MovieDetails({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<MovieDetails> createState() => _MovieDetailsState();
}

class _MovieDetailsState extends ConsumerState<MovieDetails> {
  Map<String, dynamic>? _info;
  Duration? _resume;
  late bool _fav = widget.item.isFavorite;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final item = widget.item;
    final repo = ref.read(repositoryProvider);
    final resume = await repo.resumePosition(item.sourceId, item.key);
    if (mounted) setState(() => _resume = resume);
    if (item.extId == null) return;
    try {
      final api = await ref.read(xtreamApiProvider(item.sourceId).future);
      final info = await api?.vodInfo(item.extId!);
      final i = info?['info'];
      if (mounted && i is Map) setState(() => _info = i.cast<String, dynamic>());
    } catch (_) {
      // Details are optional; the movie still plays.
    }
  }

  Future<void> _play({bool fromStart = false}) async {
    final repo = ref.read(repositoryProvider);
    final p = await playableFor(repo, widget.item);
    if (p == null) return;
    final playable = fromStart
        ? Playable(
            sourceId: p.sourceId, key: p.key, kind: p.kind, title: p.title,
            url: p.url, logo: p.logo, headers: p.headers)
        : p;
    await ref.read(appPlayerProvider).open(playable);
    if (!mounted) return;
    Navigator.pop(context);
    await PlayerPage.open(context);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final info = _info;
    final plot = xtStr(info?['plot']) ?? xtStr(info?['description']);
    final genre = xtStr(info?['genre']);
    final duration = xtStr(info?['duration']);
    final director = xtStr(info?['director']);
    final cast = xtStr(info?['cast']) ?? xtStr(info?['actors']);
    final year = xtStr(info?['releasedate'])?.split('-').first ?? item.year;
    final poster = xtStr(info?['movie_image']) ?? item.logo;
    final t = Theme.of(context).textTheme;
    final actions = [
      FilledButton.icon(
        onPressed: _play,
        icon: const Icon(Icons.play_arrow),
        label: Text(_resume != null ? 'Resume ${formatDuration(_resume!)}' : 'Play'),
      ),
      if (_resume != null)
        OutlinedButton.icon(
          onPressed: () => _play(fromStart: true),
          icon: const Icon(Icons.replay),
          label: const Text('From start'),
        ),
    ];
    final extras = [
      if (isDownloadable(item.url))
        DownloadButton(
          sourceId: item.sourceId,
          itemKey: item.key,
          onDownload: () => ref.read(downloadsProvider.notifier).addItem(item),
        ),
      IconButton.outlined(
        tooltip: _fav ? 'Remove from favorites' : 'Add to favorites',
        icon: Icon(_fav ? Icons.star : Icons.star_border, color: _fav ? AppColors.star : null),
        onPressed: () async {
          final v = await ref.read(repositoryProvider).toggleFavorite(item);
          setState(() => _fav = v);
        },
      ),
    ];
    final meta = Wrap(spacing: 12, runSpacing: 4, children: [
      if (year != null) Text(year, style: const TextStyle(color: AppColors.textDim)),
      if (duration != null) Text(duration, style: const TextStyle(color: AppColors.textDim)),
      if (item.rating != null && item.rating! > 0)
        Text('★ ${item.rating!.toStringAsFixed(1)}', style: const TextStyle(color: AppColors.star)),
      if (genre != null) Text(genre, style: const TextStyle(color: AppColors.textDim)),
    ]);
    final about = [
      if (plot != null) Text(plot, style: t.bodyMedium),
      if (director != null) ...[
        const SizedBox(height: 12),
        Text('Director: $director', style: const TextStyle(color: AppColors.textDim)),
      ],
      if (cast != null) ...[
        const SizedBox(height: 6),
        Text('Cast: $cast', style: const TextStyle(color: AppColors.textDim)),
      ],
      if (info == null && item.extId != null)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(minHeight: 2),
        ),
    ];

    if (context.isCompact) {
      // Phones: a full-screen page with the poster beside the title.
      return Dialog.fullscreen(
        backgroundColor: AppColors.bg,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(leading: const CloseButton()),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(Breakpoints.gutter, 0, Breakpoints.gutter, 24),
              children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  NetLogo(url: poster, name: item.name, width: 116, height: 174,
                      radius: AppRadii.tile, fit: BoxFit.cover),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.name, style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      meta,
                    ]),
                  ),
                ]),
                const SizedBox(height: 18),
                for (final a in actions) ...[
                  SizedBox(height: 46, child: a),
                  const SizedBox(height: 8),
                ],
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  for (final e in extras) ...[const SizedBox(width: 8), e],
                ]),
                const SizedBox(height: 12),
                ...about,
              ],
            ),
          ),
        ),
      );
    }

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 520),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: NetLogo(url: poster, name: item.name, width: 346, height: 520,
                  radius: 0, fit: BoxFit.cover),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(child: Text(item.name, style: t.headlineSmall)),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    meta,
                    const SizedBox(height: 16),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: about),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(children: [
                      for (final (i, a) in actions.indexed) ...[if (i > 0) const SizedBox(width: 8), a],
                      const Spacer(),
                      for (final (i, e) in extras.indexed) ...[if (i > 0) const SizedBox(width: 8), e],
                    ]),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SeriesPage extends ConsumerStatefulWidget {
  const SeriesPage({super.key, required this.item});
  final MediaItem item;

  @override
  ConsumerState<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends ConsumerState<SeriesPage> {
  SeriesInfo? _info;
  Object? _error;
  int? _season;
  late bool _fav = widget.item.isFavorite;
  Map<String, double> _progress = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final api = await ref.read(xtreamApiProvider(widget.item.sourceId).future);
      if (api == null || widget.item.extId == null) {
        throw StateError('Episodes are only available for Xtream Codes playlists.');
      }
      final info = await api.seriesInfo(widget.item.extId!);
      final history = await ref.read(databaseProvider).select(
          "SELECT key, position_ms, duration_ms FROM history WHERE source_id=? AND key LIKE 'ep:%'",
          [widget.item.sourceId]);
      if (!mounted) return;
      setState(() {
        _info = info;
        _season = info.episodes.isEmpty ? null : info.episodes.first.season;
        _progress = {
          for (final r in history)
            r['key'] as String: (r['duration_ms'] as int) == 0
                ? 0
                : (r['position_ms'] as int) / (r['duration_ms'] as int),
        };
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _play(Episode e) async {
    final item = widget.item;
    final key = 'ep:${e.id}';
    final repo = ref.read(repositoryProvider);
    final resume = await repo.resumePosition(item.sourceId, key);
    await ref.read(appPlayerProvider).open(Playable(
          sourceId: item.sourceId,
          key: key,
          kind: ItemKind.series,
          title: 'S${two(e.season)}E${two(e.number)} · ${e.title}',
          subtitle: item.name,
          url: e.url,
          logo: item.logo,
          resumeFrom: resume,
        ));
    if (mounted) await PlayerPage.open(context);
    _load();
  }

  Future<void> _downloadAll(List<Episode> episodes) async {
    final manager = ref.read(downloadsProvider.notifier);
    var added = 0;
    for (final e in episodes.where((e) => isDownloadable(e.url))) {
      if (manager.find(widget.item.sourceId, 'ep:${e.id}') != null) continue;
      await manager.addEpisode(widget.item, e, cover: _info?.cover);
      added++;
    }
    if (mounted) {
      showInfo(context, added == 0
          ? 'These episodes are already in Downloads'
          : 'Added $added episode${added == 1 ? '' : 's'} to Downloads');
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final info = _info;
    final t = Theme.of(context).textTheme;
    final seasons = info == null
        ? const <int>[]
        : (info.episodes.map((e) => e.season).toSet().toList()..sort());
    final episodes = info?.episodes.where((e) => e.season == _season).toList() ?? const [];
    final compact = context.isCompact;

    Widget episodeTile(Episode e) => _EpisodeTile(
          episode: e,
          compact: compact,
          progress: _progress['ep:${e.id}'],
          fallbackImage: info?.cover ?? item.logo,
          onTap: () => _play(e),
          trailing: isDownloadable(e.url)
              ? DownloadButton(
                  sourceId: item.sourceId,
                  itemKey: 'ep:${e.id}',
                  outlined: false,
                  onDownload: () =>
                      ref.read(downloadsProvider.notifier).addEpisode(item, e, cover: info?.cover),
                )
              : null,
        );
    final seasonChips = [
      for (final s in seasons)
        ChoiceChip(
          label: Text('Season $s'),
          selected: s == _season,
          onSelected: (_) => setState(() => _season = s),
        ),
    ];

    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(item.name),
          actions: [
            if (episodes.any((e) => isDownloadable(e.url)))
              compact
                  ? IconButton(
                      tooltip: seasons.length > 1 ? 'Download season $_season' : 'Download all',
                      onPressed: () => _downloadAll(episodes),
                      icon: const Icon(Icons.download_rounded),
                    )
                  : TextButton.icon(
                      onPressed: () => _downloadAll(episodes),
                      icon: const Icon(Icons.download_rounded),
                      label: Text(seasons.length > 1 ? 'Download season $_season' : 'Download all'),
                    ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: _fav ? 'Remove from favorites' : 'Add to favorites',
              icon: Icon(_fav ? Icons.star : Icons.star_border,
                  color: _fav ? AppColors.star : null),
              onPressed: () async {
                final v = await ref.read(repositoryProvider).toggleFavorite(item);
                setState(() => _fav = v);
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: _error != null
            ? EmptyState(
                icon: Icons.error_outline,
                title: 'Could not load episodes',
                message: '$_error',
                action: FilledButton(onPressed: _load, child: const Text('Retry')),
              )
            : info == null
                ? const Center(child: CircularProgressIndicator())
                : compact
                    ? _compactBody(info, seasonChips, episodes, episodeTile)
                    : Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 300,
                        child: ListView(
                          padding: const EdgeInsets.all(20),
                          children: [
                            AspectRatio(
                              aspectRatio: 2 / 3,
                              child: LayoutBuilder(
                                builder: (_, c) => NetLogo(
                                  url: info.cover ?? item.logo,
                                  name: item.name,
                                  width: c.maxWidth,
                                  height: c.maxHeight,
                                  radius: 10,
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (info.genre != null)
                              Text(info.genre!, style: const TextStyle(color: AppColors.textDim)),
                            if (info.releaseDate != null)
                              Text(info.releaseDate!, style: const TextStyle(color: AppColors.textDim)),
                            if (info.plot != null) ...[
                              const SizedBox(height: 12),
                              Text(info.plot!, style: t.bodyMedium),
                            ],
                            if (info.cast != null) ...[
                              const SizedBox(height: 12),
                              Text('Cast: ${info.cast}', style: const TextStyle(color: AppColors.textDim)),
                            ],
                          ],
                        ),
                      ),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (seasons.length > 1)
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                                child: Wrap(spacing: 8, runSpacing: 8, children: seasonChips),
                              ),
                            Expanded(
                              child: episodes.isEmpty
                                  ? const EmptyState(icon: Icons.video_library_outlined, title: 'No episodes')
                                  : ListView.separated(
                                      padding: const EdgeInsets.all(16),
                                      itemCount: episodes.length,
                                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                                      itemBuilder: (_, i) => episodeTile(episodes[i]),
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }

  /// Phones: one scrolling column — cover and facts, seasons, episodes.
  Widget _compactBody(SeriesInfo info, List<Widget> seasonChips, List<Episode> episodes,
      Widget Function(Episode) episodeTile) {
    final item = widget.item;
    return SafeArea(
      top: false,
      child: CustomScrollView(slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Breakpoints.gutter, 4, Breakpoints.gutter, 8),
          sliver: SliverList.list(children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              NetLogo(url: info.cover ?? item.logo, name: item.name, width: 104, height: 156,
                  radius: AppRadii.tile, fit: BoxFit.cover),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(item.name,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  if (info.genre != null) Text(info.genre!, style: const TextStyle(color: AppColors.textDim)),
                  if (info.releaseDate != null)
                    Text(info.releaseDate!, style: const TextStyle(color: AppColors.textDim)),
                ]),
              ),
            ]),
            if (info.plot != null) ...[
              const SizedBox(height: 14),
              Text(info.plot!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (info.cast != null) ...[
              const SizedBox(height: 8),
              Text('Cast: ${info.cast}',
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.textDim)),
            ],
          ]),
        ),
        if (seasonChips.length > 1)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(Breakpoints.gutter, 8, Breakpoints.gutter, 4),
              child: Row(children: [
                for (final c in seasonChips) Padding(padding: const EdgeInsets.only(right: 8), child: c),
              ]),
            ),
          ),
        if (episodes.isEmpty)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(icon: Icons.video_library_outlined, title: 'No episodes'),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
            sliver: SliverList.separated(
              itemCount: episodes.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (_, i) => episodeTile(episodes[i]),
            ),
          ),
      ]),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.episode,
    required this.onTap,
    this.progress,
    this.fallbackImage,
    this.trailing,
    this.compact = false,
  });

  final bool compact;
  final Episode episode;
  final VoidCallback onTap;
  final double? progress;
  final String? fallbackImage;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Stack(children: [
                  NetLogo(
                    url: episode.image ?? fallbackImage,
                    name: episode.title,
                    width: compact ? 112 : 160,
                    height: compact ? 63 : 90,
                    fit: BoxFit.cover,
                  ),
                  if (progress != null && progress! > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: LinearProgressIndicator(value: progress, minHeight: 3),
                    ),
                ]),
                SizedBox(width: compact ? 10 : 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${episode.number}. ${episode.title}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          maxLines: compact ? 2 : 1,
                          overflow: TextOverflow.ellipsis),
                      if (episode.duration != null)
                        Text(episode.duration!,
                            style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                      if (episode.plot != null) ...[
                        const SizedBox(height: 4),
                        Text(episode.plot!,
                            maxLines: compact ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: AppColors.textDim, fontSize: 13)),
                      ],
                    ],
                  ),
                ),
                ?trailing,
                if (!compact) ...[
                  const SizedBox(width: 4),
                  const Icon(Icons.play_circle_outline, size: 32),
                ],
              ],
            ),
          ),
        ),
      );
}
