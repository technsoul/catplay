import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../features/guide/guide_page.dart';
import '../features/home/home_page.dart';
import '../features/live/live_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/sources_page.dart';
import '../features/vod/vod_page.dart';
import '../import/import_service.dart';
import '../player/app_player.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'providers.dart';

enum Section { home, live, guide, movies, series, search, playlists, settings }

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Section _section = Section.home;
  final _visited = <Section>{Section.home};
  final _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Refresh stale playlists/guides shortly after start-up.
    Timer(const Duration(seconds: 2), () {
      if (mounted) ref.read(importProvider.notifier).refreshStale();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoplay());
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _autoplay() async {
    final s = ref.read(settingsProvider);
    final key = s.lastChannelKey;
    if (!s.autoplayLastChannel || key == null) return;
    final sep = key.indexOf('|');
    if (sep <= 0) return;
    final repo = ref.read(repositoryProvider);
    final item = await repo.itemByKey(int.parse(key.substring(0, sep)), key.substring(sep + 1));
    if (item == null) return;
    final p = await playableFor(repo, item);
    if (p == null) return;
    await ref.read(appPlayerProvider).open(p);
    _go(Section.live);
  }

  void _go(Section s) {
    setState(() {
      _section = s;
      _visited.add(s);
    });
    if (s == Section.search) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _searchFocus.requestFocus());
    }
  }

  @override
  Widget build(BuildContext context) {
    final sourcesAsync = ref.watch(sourcesProvider);
    final source = ref.watch(activeSourceProvider);
    final sources = sourcesAsync.value ?? const [];

    if (sourcesAsync.isLoading && sources.isEmpty) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (sources.isEmpty) return const _Welcome();

    final needsSource = source == null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _go(Section.search),
      },
      child: Scaffold(
        body: Row(
          children: [
            _Rail(section: _section, onSelect: _go),
            Expanded(
              child: Column(
                children: [
                  _TopBar(source: source, sources: sources, onPlaylists: () => _go(Section.playlists)),
                  Expanded(
                    child: needsSource
                        ? const SizedBox.shrink()
                        : IndexedStack(
                            index: _section.index,
                            children: [
                              for (final s in Section.values)
                                _visited.contains(s) ? _page(s, source) : const SizedBox.shrink(),
                            ],
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

  Widget _page(Section s, Source source) => switch (s) {
        Section.home => HomePage(source: source, onNavigate: (i) => _go(Section.values[i])),
        Section.live => LivePage(source: source),
        Section.guide => GuidePage(source: source),
        Section.movies => VodPage(source: source, kind: ItemKind.movie),
        Section.series => VodPage(source: source, kind: ItemKind.series),
        Section.search => SearchPage(focusNode: _searchFocus),
        Section.playlists => const SourcesPage(),
        Section.settings => const SettingsPage(),
      };
}

class _Rail extends ConsumerWidget {
  const _Rail({required this.section, required this.onSelect});
  final Section section;
  final ValueChanged<Section> onSelect;

  static const _items = [
    (Section.home, Icons.home_outlined, Icons.home, 'Home'),
    (Section.live, Icons.live_tv_outlined, Icons.live_tv, 'Live TV'),
    (Section.guide, Icons.calendar_view_week_outlined, Icons.calendar_view_week, 'TV Guide'),
    (Section.movies, Icons.movie_outlined, Icons.movie, 'Movies'),
    (Section.series, Icons.video_library_outlined, Icons.video_library, 'Series'),
    (Section.search, Icons.search, Icons.search, 'Search'),
    (Section.playlists, Icons.playlist_play_outlined, Icons.playlist_play, 'Playlists'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final importing = ref.watch(importProvider).values.any((s) => s.running);
    return SizedBox(
      width: 88,
      child: Column(children: [
        const SizedBox(height: 18),
        Image.asset('assets/brand/mark.png', width: 40, height: 40, filterQuality: FilterQuality.medium),
        const SizedBox(height: 28),
        Expanded(
          child: SingleChildScrollView(
            child: Column(children: [
              for (final (s, icon, selectedIcon, label) in _items)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: RoundIconButton(
                    icon: section == s ? selectedIcon : icon,
                    tooltip: label,
                    selected: section == s,
                    onPressed: () => onSelect(s),
                  ),
                ),
            ]),
          ),
        ),
        if (importing)
          const Padding(
            padding: EdgeInsets.only(bottom: 14),
            child: Tooltip(
              message: 'Updating playlists…',
              child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: RoundIconButton(
            icon: section == Section.settings ? Icons.settings : Icons.settings_outlined,
            tooltip: 'Settings',
            selected: section == Section.settings,
            onPressed: () => onSelect(Section.settings),
          ),
        ),
      ]),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({required this.source, required this.sources, required this.onPlaylists});
  final Source? source;
  final List<Source> sources;
  final VoidCallback onPlaylists;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = source == null ? null : ref.watch(importProvider)[source!.id];
    final busy = status != null && !status.finished;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 24, 0),
        child: Row(children: [
          const Icon(Icons.playlist_play, color: AppColors.textDim),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: source?.id,
            underline: const SizedBox.shrink(),
            items: [
              for (final s in sources) DropdownMenuItem(value: s.id, child: Text(s.name)),
            ],
            onChanged: (id) => ref
                .read(settingsProvider.notifier)
                .update((s) => s.copyWith(activeSourceId: id)),
          ),
          const SizedBox(width: 16),
          if (busy) ...[
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Flexible(
              child: Text(status.message,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ),
          ] else if (source?.status == 'error')
            Flexible(
              child: InkWell(
                onTap: onPlaylists,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline, size: 16, color: AppColors.live),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(source!.error ?? 'Update failed',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.live, fontSize: 12)),
                  ),
                ]),
              ),
            ),
          const Spacer(),
          const _Clock(),
        ]),
      ),
    );
  }
}

/// Launcher-style time and date in the top-right corner.
class _Clock extends StatefulWidget {
  const _Clock();
  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  late Timer _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('${_days[_now.weekday - 1]}, ${_months[_now.month - 1]} ${_now.day}',
              style: const TextStyle(color: AppColors.textSoft, fontSize: 15, fontWeight: FontWeight.w300)),
          const SizedBox(width: 14),
          Text(hhmm(_now),
              style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w300, letterSpacing: -0.5)),
        ],
      );
}

class _Welcome extends StatelessWidget {
  const _Welcome();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/brand/logo.png', height: 180, filterQuality: FilterQuality.medium),
              const SizedBox(height: 28),
              Text('Welcome to CAT',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 12),
              const Text(
                'Add your Xtream Codes login or an M3U playlist to get started. '
                'This app does not include any channels — you need a subscription from your provider.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textDim),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 18)),
                onPressed: () => showSourceDialog(context),
                icon: const Icon(Icons.add),
                label: const Text('Add playlist'),
              ),
              const SizedBox(height: 40),
              const EmptyState(
                icon: Icons.tips_and_updates_outlined,
                title: 'Supports',
                message: 'Xtream Codes API · M3U / M3U8 (URL or file) · XMLTV guides (.xml / .xml.gz) · '
                    'catch-up · HEVC, AC3/E-AC3 and almost every other codec via libmpv',
              ),
            ]),
          ),
        ),
      );
}
