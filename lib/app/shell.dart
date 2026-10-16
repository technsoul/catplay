import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../downloads/downloads.dart';
import '../features/downloads/downloads_page.dart';
import '../features/guide/guide_page.dart';
import '../features/home/home_page.dart';
import '../features/live/live_page.dart';
import '../features/search/search_page.dart';
import '../features/settings/settings_page.dart';
import '../features/sources/sources_page.dart';
import '../features/vod/vod_page.dart';
import '../import/import_service.dart';
import '../player/app_player.dart';
import '../player/player_view.dart';
import '../ui/source_picker.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'providers.dart';

enum Section { home, live, guide, movies, series, search, playlists, settings, downloads }

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  Section _section = Section.home;
  final _visited = <Section>{Section.home};
  final _searchFocus = FocusNode();
  final _pagesKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Refresh stale playlists/guides shortly after start-up.
    Timer(const Duration(seconds: 2), () {
      if (mounted) ref.read(importProvider.notifier).refreshStale();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoplay());
    // Resume downloads interrupted by the last exit.
    ref.read(downloadsProvider);
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
    // Keyed so pages keep their state when the layout switches (a phone
    // rotating, a desktop window resized).
    final pages = needsSource
        ? const SizedBox.shrink()
        : IndexedStack(
            key: _pagesKey,
            index: _section.index,
            children: [
              for (final s in Section.values)
                _visited.contains(s) ? _page(s, source) : const SizedBox.shrink(),
            ],
          );
    final compact = context.isCompact;
    final landscape = context.isCompactLandscape;

    return PopScope(
      // Back (phone gesture, TV remote) returns to Home before leaving.
      canPop: _section == Section.home,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _go(Section.home);
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => _go(Section.search),
        },
        child: Scaffold(
          body: AppBackdrop(
            hero: _section == Section.home,
            child: compact
                ? _compactBody(pages, source, landscape: landscape)
                : _wideBody(pages, source),
          ),
          bottomNavigationBar: compact && !landscape
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  if (_section != Section.live) const _NowPlayingBar(),
                  _BottomNav(section: _section, onSelect: _go, onMore: _showMore),
                ])
              : null,
        ),
      ),
    );
  }

  Widget _wideBody(Widget pages, Source? source) => Row(
        children: [
          // Home is a full-screen launcher; the rail slides in elsewhere.
          ClipRect(
            child: AnimatedAlign(
              alignment: Alignment.centerRight,
              widthFactor: _section == Section.home ? 0 : 1,
              duration: AppMotion.base,
              curve: AppMotion.curve,
              child: ExcludeFocus(
                excluding: _section == Section.home,
                child: _Rail(section: _section, onSelect: _go),
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  source: source,
                  // Home shows its own big clock.
                  showClock: _section != Section.home,
                ),
                Expanded(child: pages),
              ],
            ),
          ),
        ],
      );

  /// Phones: pages fill the screen under the status bar; navigation is a
  /// bottom bar (portrait) or a slim rail (landscape).
  Widget _compactBody(Widget pages, Source? source, {required bool landscape}) {
    final content = SafeArea(
      bottom: landscape,
      left: !landscape,
      child: Column(children: [
        _ImportProgressLine(source: source),
        Expanded(child: pages),
        if (landscape && _section != Section.live) const _NowPlayingBar(),
      ]),
    );
    if (!landscape) return content;
    return Row(children: [
      SafeArea(
        right: false,
        child: _CompactRail(section: _section, onSelect: _go, onMore: _showMore),
      ),
      Expanded(child: content),
    ]);
  }

  Future<void> _showMore() async {
    final s = await showModalBottomSheet<Section>(
      context: context,
      backgroundColor: AppColors.sheet,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _MoreSheet(current: _section),
    );
    if (s != null) _go(s);
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
        Section.downloads => const DownloadsPage(),
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
    (Section.downloads, Icons.download_outlined, Icons.download, 'Downloads'),
    (Section.playlists, Icons.playlist_play_outlined, Icons.playlist_play, 'Playlists'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final importing = ref.watch(importProvider).values.any((s) => s.running);
    final downloading = ref.watch(downloadsProvider.select((l) => l.where((t) => t.isActive).length));
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
                _RailItem(
                  icon: section == s ? selectedIcon : icon,
                  label: s == Section.downloads && downloading > 0
                      ? 'Downloads ($downloading in progress)'
                      : label,
                  selected: section == s,
                  badge: s == Section.downloads && downloading > 0,
                  onPressed: () => onSelect(s),
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
          child: _RailItem(
            icon: section == Section.settings ? Icons.settings : Icons.settings_outlined,
            label: 'Settings',
            selected: section == Section.settings,
            onPressed: () => onSelect(Section.settings),
          ),
        ),
      ]),
    );
  }
}

/// A rail button with an amber marker on the rail's left edge when selected.
class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.badge = false,
    this.width = 88,
  });
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onPressed;
  final bool badge;
  final double width;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        height: 58,
        child: Stack(alignment: Alignment.center, children: [
          Positioned(
            left: 0,
            child: AnimatedContainer(
              duration: AppMotion.base,
              curve: AppMotion.curve,
              width: 4,
              height: selected ? 24 : 0,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: const BorderRadius.horizontal(right: Radius.circular(3)),
                boxShadow: selected
                    ? [BoxShadow(color: AppColors.accent.withValues(alpha: 0.5), blurRadius: 10)]
                    : null,
              ),
            ),
          ),
          RoundIconButton(icon: icon, tooltip: label, selected: selected, onPressed: onPressed),
          if (badge)
            Positioned(
              top: 10,
              right: (width - 48) / 2 - 2,
              child: const IgnorePointer(
                child: SizedBox(
                  width: 9,
                  height: 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: AppColors.accentBright, shape: BoxShape.circle),
                  ),
                ),
              ),
            ),
        ]),
      );
}

/// Phone navigation: the four main sections, then "More" for the rest.
const _primary = [
  (Section.home, Icons.home_outlined, Icons.home_rounded, 'Home'),
  (Section.live, Icons.live_tv_outlined, Icons.live_tv_rounded, 'Live TV'),
  (Section.movies, Icons.movie_outlined, Icons.movie_rounded, 'Movies'),
  (Section.series, Icons.video_library_outlined, Icons.video_library_rounded, 'Series'),
];

const _secondary = [
  (Section.search, Icons.search_rounded, 'Search', 'Channels, movies and series'),
  (Section.guide, Icons.calendar_view_week_rounded, 'TV Guide', "What's on now and later"),
  (Section.downloads, Icons.download_rounded, 'Downloads', 'Watch offline'),
  (Section.playlists, Icons.playlist_play_rounded, 'Playlists', 'Add, switch or refresh playlists'),
  (Section.settings, Icons.settings_outlined, 'Settings', 'Playback, guide, app lock'),
];

bool _inMore(Section s) => _secondary.any((e) => e.$1 == s);

class _BottomNav extends ConsumerWidget {
  const _BottomNav({required this.section, required this.onSelect, required this.onMore});
  final Section section;
  final ValueChanged<Section> onSelect;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloading = ref.watch(downloadsProvider.select((l) => l.where((t) => t.isActive).length));
    final selected = _inMore(section) ? _primary.length : _primary.indexWhere((e) => e.$1 == section);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0xF2101828),
        border: Border(top: BorderSide(color: AppColors.glassBorder)),
      ),
      child: NavigationBarTheme(
        data: NavigationBarThemeData(
          backgroundColor: Colors.transparent,
          indicatorColor: AppColors.glassStrong,
          height: 64,
          labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
                fontSize: 12,
                fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400,
                color: s.contains(WidgetState.selected) ? AppColors.text : AppColors.textDim,
              )),
          iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(
                color: s.contains(WidgetState.selected) ? AppColors.accentBright : AppColors.textSoft,
              )),
        ),
        child: NavigationBar(
          selectedIndex: selected,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) => i == _primary.length ? onMore() : onSelect(_primary[i].$1),
          destinations: [
            for (final (_, icon, selectedIcon, label) in _primary)
              NavigationDestination(icon: Icon(icon), selectedIcon: Icon(selectedIcon), label: label),
            NavigationDestination(
              icon: Badge(isLabelVisible: downloading > 0, child: const Icon(Icons.menu_rounded)),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}

/// Phones in landscape: the bottom bar would eat the short screen, so the
/// same destinations go in a slim rail on the left.
class _CompactRail extends ConsumerWidget {
  const _CompactRail({required this.section, required this.onSelect, required this.onMore});
  final Section section;
  final ValueChanged<Section> onSelect;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloading = ref.watch(downloadsProvider.select((l) => l.where((t) => t.isActive).length));
    return SizedBox(
      width: 72,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(children: [
          for (final (s, icon, selectedIcon, label) in _primary)
            _RailItem(
              width: 72,
              icon: section == s ? selectedIcon : icon,
              label: label,
              selected: section == s,
              onPressed: () => onSelect(s),
            ),
          _RailItem(
            width: 72,
            icon: Icons.menu_rounded,
            label: 'More',
            selected: _inMore(section),
            badge: downloading > 0,
            onPressed: onMore,
          ),
        ]),
      ),
    );
  }
}

class _MoreSheet extends ConsumerWidget {
  const _MoreSheet({required this.current});
  final Section current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloading = ref.watch(downloadsProvider.select((l) => l.where((t) => t.isActive).length));
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (s, icon, label, about) in _secondary)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: GlassTile(
                selected: s == current,
                onTap: () => Navigator.pop(context, s),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(children: [
                  Icon(icon, color: s == current ? AppColors.accentBright : AppColors.textSoft),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                      Text(
                        s == Section.downloads && downloading > 0 ? '$downloading in progress' : about,
                        style: const TextStyle(color: AppColors.textDim, fontSize: 12),
                      ),
                    ]),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppColors.textDim),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Thin progress line while the active playlist is importing (the compact
/// layout has no top bar to show the status text in).
class _ImportProgressLine extends ConsumerWidget {
  const _ImportProgressLine({required this.source});
  final Source? source;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = source == null ? null : ref.watch(importProvider)[source!.id];
    if (st == null || st.finished) return const SizedBox.shrink();
    return Tooltip(
      message: st.message,
      child: LinearProgressIndicator(minHeight: 2, value: st.queued ? null : st.fraction),
    );
  }
}

/// What's playing, shown above the phone navigation while browsing other
/// sections. Tap to open the player, × to stop.
class _NowPlayingBar extends ConsumerWidget {
  const _NowPlayingBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ap = ref.watch(appPlayerProvider);
    return ValueListenableBuilder(
      valueListenable: ap.state,
      builder: (context, s, _) {
        final p = s.playable;
        if (p == null || s.phase == PlayPhase.idle) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
          child: GlassTile(
            onTap: () => PlayerPage.open(context, stopOnExit: false),
            padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
            child: Row(children: [
              NetLogo(url: p.logo, name: p.title, width: 52, height: 36, radius: 8),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (p.isLive && p.epgId != null)
                      DefaultTextStyle.merge(
                        style: const TextStyle(fontSize: 12),
                        child: NowPlayingLine(sourceId: p.sourceId, epgId: p.epgId!),
                      )
                    else if (p.subtitle != null)
                      Text(p.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                  ],
                ),
              ),
              StreamBuilder<bool>(
                stream: ap.player.stream.playing,
                initialData: ap.player.state.playing,
                builder: (_, snap) => IconButton(
                  tooltip: snap.data == true ? 'Pause' : 'Play',
                  icon: Icon(snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded),
                  onPressed: ap.player.playOrPause,
                ),
              ),
              IconButton(
                tooltip: 'Stop',
                icon: const Icon(Icons.close_rounded),
                onPressed: ap.stop,
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar({
    required this.source,
    required this.showClock,
  });
  final Source? source;
  final bool showClock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = source == null ? null : ref.watch(importProvider)[source!.id];
    final busy = status != null && !status.finished;
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 24, 0),
        child: Row(children: [
          const SourcePicker(),
          const SizedBox(width: 16),
          if (busy) ...[
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(status.message,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ),
          ] else
            const Spacer(),
          // Import errors are shown on the Playlists page, not up here.
          if (showClock) const _Clock(),
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
        body: AppBackdrop(
          hero: true,
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Breakpoints.gutter),
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Image.asset('assets/brand/logo.png',
                    height: context.isCompact ? 120 : 180, filterQuality: FilterQuality.medium),
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
              ].animate(interval: 70.ms).fadeIn(duration: 450.ms).slideY(begin: 0.08)),
                ),
              ),
            ),
          ),
        ),
      );
}
