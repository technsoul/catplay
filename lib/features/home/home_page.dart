import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glass_kit/glass_kit.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../data/repository.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/source_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../vod/details.dart';

/// TV-launcher hero (greeting, glass section cards, big clock), then
/// continue watching, recent channels and favorites below the fold.
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

    final sections = <Widget>[
      if (_continue.isNotEmpty) ...[
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
        const SizedBox(height: 24),
      ],
      if (_recent.isNotEmpty) ...[
        const SectionTitle('Recently watched channels'),
        _ChannelRow(children: [
          for (final h in _recent) _ChannelChip(name: h.name, logo: h.logo, onTap: () => _resume(h)),
        ]),
        const SizedBox(height: 24),
      ],
      if (_favChannels.isNotEmpty) ...[
        const SectionTitle('Favorite channels'),
        _ChannelRow(children: [
          for (final c in _favChannels)
            _ChannelChip(name: c.name, logo: c.logo, onTap: () => openDetails(context, ref, c)),
        ]),
        const SizedBox(height: 24),
      ],
      if (_favVod.isNotEmpty) ...[
        const SectionTitle('Favorite movies'),
        _PosterRow(items: _favVod),
        const SizedBox(height: 24),
      ],
      if (_newMovies.isNotEmpty) ...[
        const SectionTitle('Recently added movies'),
        _PosterRow(items: _newMovies),
        const SizedBox(height: 24),
      ],
    ];

    if (context.isCompact) {
      return CustomScrollView(slivers: [
        SliverToBoxAdapter(child: _CompactHero(source: widget.source, onNavigate: widget.onNavigate)),
        if (sections.isNotEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(Breakpoints.gutter - 4, 8, 0, 16),
            sliver: SliverList.list(
              children: sections.animate(interval: 40.ms).fadeIn(duration: 400.ms),
            ),
          ),
      ]);
    }

    return Stack(children: [
      const Positioned.fill(child: IgnorePointer(child: _LogoMark())),
      LayoutBuilder(
        builder: (context, c) => CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: math.max(c.maxHeight, 520),
              child: _Hero(source: widget.source, onNavigate: widget.onNavigate),
            ),
          ),
          if (sections.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(48, 8, 32, 16),
              sliver: SliverList.list(
                children: sections
                    .animate(interval: 40.ms)
                    .fadeIn(duration: 400.ms)
                    .slideY(begin: 0.08, curve: Curves.easeOutCubic),
              ),
            ),
        ]),
      ),
    ]);
  }
}

/// Phone launcher: brand row with search and settings, the playlist picker,
/// a greeting and the four sections as a 2×2 grid (one row in landscape).
class _CompactHero extends StatelessWidget {
  const _CompactHero({required this.source, required this.onNavigate});
  final Source source;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final s = source;
    final hour = DateTime.now().hour;
    final greeting = hour < 12
        ? 'Good morning'
        : hour < 18
            ? 'Good afternoon'
            : 'Good evening';
    final cards = [
      (Icons.live_tv_rounded, 'Live TV', '${formatCount(s.liveCount)} channels', 1),
      (Icons.movie_outlined, 'Movies', '${formatCount(s.movieCount)} titles', 3),
      (Icons.video_library_outlined, 'Series', '${formatCount(s.seriesCount)} shows', 4),
      (Icons.calendar_view_week_rounded, 'TV Guide', "What's on now", 2),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(Breakpoints.gutter, 12, Breakpoints.gutter, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Image.asset('assets/brand/mark.png', width: 34, height: 34, filterQuality: FilterQuality.medium),
          const SizedBox(width: 10),
          const Text('CAT',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          const Spacer(),
          RoundIconButton(
              size: 42, icon: Icons.search_rounded, tooltip: 'Search', onPressed: () => onNavigate(5)),
          const SizedBox(width: 8),
          RoundIconButton(
              size: 42, icon: Icons.settings_outlined, tooltip: 'Settings', onPressed: () => onNavigate(7)),
        ]).animate().fadeIn(duration: 400.ms),
        const SizedBox(height: 18),
        Text('$greeting · ${hhmm(DateTime.now())}',
            style: const TextStyle(color: AppColors.textDim, fontSize: 14, fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text('What are we watching ${hour >= 18 ? 'tonight' : 'today'}?',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4, height: 1.2)),
        if (s.expiresAt != null && s.expiresAt!.difference(DateTime.now()).inDays < 14) ...[
          const SizedBox(height: 6),
          _Expiry(expiresAt: s.expiresAt!),
        ],
        const SizedBox(height: 14),
        const Align(alignment: Alignment.centerLeft, child: SourcePicker(maxWidth: 320)),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, c) {
          final columns = c.maxWidth >= 560 ? 4 : 2;
          const gap = 12.0;
          final w = (c.maxWidth - gap * (columns - 1)) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            for (final (i, (icon, title, sub, target)) in cards.indexed)
              SizedBox(
                width: w,
                height: 116,
                child: GlassTile(
                  radius: AppRadii.card,
                  onTap: () => onNavigate(target),
                  padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(icon, size: 30, color: AppColors.accentBright),
                    const Spacer(),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.3)),
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textSoft, fontSize: 13)),
                  ]),
                ),
              )
                  .animate(delay: (120 + i * 60).ms)
                  .fadeIn(duration: 400.ms)
                  .slideY(begin: 0.15, curve: Curves.easeOutCubic),
          ]);
        }),
      ]),
    );
  }
}

/// The CAT logo, large and faint, floating behind the launcher.
class _LogoMark extends StatelessWidget {
  const _LogoMark();

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        final size = math.min(w * 0.42, h * 0.8);
        return Stack(children: [
          Positioned(
            left: w * 0.56,
            top: h * 0.08,
            child: Opacity(
              opacity: 0.2,
              child: Image.asset('assets/brand/mark.png',
                  width: size, height: size, filterQuality: FilterQuality.medium),
            )
                .animate(onPlay: (ctl) => ctl.repeat(reverse: true))
                .moveY(begin: -10, end: 10, duration: 6.seconds, curve: Curves.easeInOutSine),
          ),
        ]);
      }).animate().fadeIn(duration: 1200.ms, curve: Curves.easeOut);
}

class _Hero extends StatelessWidget {
  const _Hero({required this.source, required this.onNavigate});
  final Source source;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        // Everything scales with the page so it reads well from the sofa
        // and on a small laptop window alike.
        final k = math.min(c.maxWidth / 1272, c.maxHeight / 700).clamp(0.62, 1.35);
        final wide = c.maxWidth >= 900;
        final s = source;
        final hour = DateTime.now().hour;
        final greeting = hour < 12
            ? 'Good morning'
            : hour < 18
                ? 'Good afternoon'
                : 'Good evening';
        final cards = [
          _CardSpec(
            icon: Icons.live_tv_rounded,
            title: 'Live TV',
            sub: '${formatCount(s.liveCount)} channels',
            note: 'Updated ${formatRelative(s.lastRefresh)}',
            onTap: () => onNavigate(1),
          ),
          _CardSpec(
            icon: Icons.movie_outlined,
            title: 'Movies',
            sub: '${formatCount(s.movieCount)} titles',
            onTap: () => onNavigate(3),
          ),
          _CardSpec(
            icon: Icons.video_library_outlined,
            title: 'Series',
            sub: '${formatCount(s.seriesCount)} shows',
            onTap: () => onNavigate(4),
          ),
          _CardSpec(
            icon: Icons.calendar_view_week_rounded,
            title: 'TV Guide',
            sub: "What's on now",
            onTap: () => onNavigate(2),
          ),
        ];

        return Padding(
          padding: EdgeInsets.fromLTRB(56 * k, 36 * k, 56 * k, 28 * k),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Header(source: s, k: k, onNavigate: onNavigate)
                .animate()
                .fadeIn(duration: 450.ms)
                .slideY(begin: -0.4, curve: Curves.easeOutCubic),
            Expanded(
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ...[
                      Text('$greeting · ${s.name}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: AppColors.textDim, fontSize: 15 * k, fontWeight: FontWeight.w600)),
                      SizedBox(height: 6 * k),
                      Text('What are we watching ${hour >= 18 ? 'tonight' : 'today'}?',
                          maxLines: 2,
                          style: TextStyle(
                              color: AppColors.text,
                              fontSize: 34 * k,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.6,
                              height: 1.15)),
                      if (s.expiresAt != null &&
                          s.expiresAt!.difference(DateTime.now()).inDays < 14) ...[
                        SizedBox(height: 6 * k),
                        _Expiry(expiresAt: s.expiresAt!),
                      ],
                      ]
                          .animate(delay: 150.ms, interval: 70.ms)
                          .fadeIn(duration: 500.ms)
                          .slideX(begin: -0.06, curve: Curves.easeOutCubic),
                      SizedBox(height: 28 * k),
                      _CardRow(cards: cards, k: k),
                    ],
                  ),
                ),
                if (wide) ...[
                  SizedBox(width: 40 * k),
                  Padding(
                    padding: EdgeInsets.only(bottom: 44 * k),
                    child: _BigClock(k: k),
                  )
                      .animate(delay: 300.ms)
                      .fadeIn(duration: 600.ms)
                      .slideX(begin: 0.15, curve: Curves.easeOutCubic),
                ],
              ]),
            ),
            if (c.maxHeight > 600) ...[
              SizedBox(height: 18 * k),
              _KeyHints(k: k).animate(delay: 800.ms).fadeIn(duration: 600.ms),
            ],
          ]),
        );
      });
}

class _Header extends StatelessWidget {
  const _Header({required this.source, required this.k, required this.onNavigate});
  final Source source;
  final double k;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) => Row(children: [
        Image.asset('assets/brand/mark.png',
            width: 42 * k, height: 42 * k, filterQuality: FilterQuality.medium),
        SizedBox(width: 12 * k),
        Text('CAT',
            style: TextStyle(
                color: AppColors.text, fontSize: 28 * k, fontWeight: FontWeight.w800, letterSpacing: -0.6)),
        SizedBox(width: 8 * k),
        Padding(
          padding: EdgeInsets.only(top: 6 * k),
          child: Text('IPTV',
              style: TextStyle(
                  color: AppColors.textDim, fontSize: 12 * k, fontWeight: FontWeight.w700, letterSpacing: 2)),
        ),
        SizedBox(width: 28 * k),
        Container(width: 1, height: 36 * k, color: Colors.white.withValues(alpha: 0.16)),
        SizedBox(width: 28 * k),
        Flexible(child: _SearchPill(k: k, onTap: () => onNavigate(5))),
        const Spacer(),
        RoundIconButton(
          size: 52 * k,
          icon: Icons.playlist_play_rounded,
          tooltip: 'Playlists',
          onPressed: () => onNavigate(6),
        ),
        SizedBox(width: 14 * k),
        RoundIconButton(
          size: 52 * k,
          icon: Icons.settings_outlined,
          tooltip: 'Settings',
          onPressed: () => onNavigate(7),
        ),
        SizedBox(width: 14 * k),
        _Avatar(k: k, name: source.name, onTap: () => onNavigate(6)),
      ]);
}

/// Opens the search page; the real text field lives there.
class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.k, required this.onTap});
  final double k;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380 * k),
        child: Semantics(
          button: true,
          label: 'Search',
          child: GlassContainer(
            height: 56 * k,
            blur: 20,
            color: Colors.white.withValues(alpha: 0.06),
            borderColor: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(28 * k),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6 * k),
                  child: Row(children: [
                    Container(
                      width: 44 * k,
                      height: 44 * k,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12)),
                      child: Icon(Icons.search_rounded, size: 20 * k, color: AppColors.text),
                    ),
                    SizedBox(width: 14 * k),
                    Expanded(
                      child: Text('Search channels, movies, series…',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: AppColors.textDim, fontSize: 16 * k)),
                    ),
                    Text('Ctrl F',
                        style: TextStyle(
                            color: AppColors.textDim, fontSize: 12 * k, fontWeight: FontWeight.w600)),
                    SizedBox(width: 16 * k),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

/// Initial of the active playlist, ringed in the accent colour.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.k, required this.name, required this.onTap});
  final double k;
  final String name;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: name,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 56 * k,
            height: 56 * k,
            padding: EdgeInsets.all(3 * k),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.accent, width: 2),
            ),
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: AppColors.sheetHigh),
              child: Text(
                name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                style: TextStyle(color: AppColors.text, fontSize: 16 * k, fontWeight: FontWeight.w800),
              ),
            ),
          ),
        ),
      );
}

class _CardSpec {
  const _CardSpec({
    required this.icon,
    required this.title,
    required this.sub,
    required this.onTap,
    this.note,
  });
  final IconData icon;
  final String title;
  final String sub;
  final String? note;
  final VoidCallback onTap;
}

/// The four section cards. The focused one (keyboard, remote or hover)
/// grows, brightens and gets a glowing bar beneath it.
class _CardRow extends StatefulWidget {
  const _CardRow({required this.cards, required this.k});
  final List<_CardSpec> cards;
  final double k;

  @override
  State<_CardRow> createState() => _CardRowState();
}

class _CardRowState extends State<_CardRow> {
  int _focused = 0;

  void _focus(int i) {
    if (_focused != i) setState(() => _focused = i);
  }

  @override
  Widget build(BuildContext context) {
    final k = widget.k;
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < widget.cards.length; i++) ...[
            if (i > 0) SizedBox(width: 20 * k),
            _GlassCard(
              spec: widget.cards[i],
              k: k,
              focused: _focused == i,
              onFocus: () => _focus(i),
            )
                .animate(delay: (250 + i * 90).ms)
                .fadeIn(duration: 450.ms)
                .slideY(begin: 0.25, curve: Curves.easeOutCubic)
                .scaleXY(begin: 0.94, curve: Curves.easeOutCubic),
          ],
        ]),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.spec, required this.k, required this.focused, required this.onFocus});
  final _CardSpec spec;
  final double k;
  final bool focused;
  final VoidCallback onFocus;

  @override
  Widget build(BuildContext context) => FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (v) {
          if (v) onFocus();
        },
        onFocusChange: (v) {
          if (v) onFocus();
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            spec.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: spec.onTap,
          child: Semantics(
            button: true,
            label: '${spec.title}, ${spec.sub}',
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: focused ? 1 : 0),
                duration: 260.ms,
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => _card(t),
              ),
              SizedBox(height: 16 * k),
              FocusGlowBar(active: focused, length: 56 * k),
            ]),
          ),
        ),
      );

  Widget _card(double t) {
    double lerp(double a, double b) => a + (b - a) * t;
    final radius = BorderRadius.circular(14 * k);
    return Opacity(
      opacity: lerp(0.82, 1),
      child: GlassContainer(
        width: lerp(216, 256) * k,
        height: lerp(330, 384) * k,
        blur: 24,
        borderRadius: radius,
        borderWidth: 1,
        color: Colors.white.withValues(alpha: lerp(0.06, 0.16)),
        borderColor: Colors.white.withValues(alpha: lerp(0.10, 0.34)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5 * t),
            blurRadius: 70,
            offset: const Offset(0, 30),
          ),
        ],
        child: Stack(children: [
          // Sheen across the top half.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: lerp(330, 384) * k / 2,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: 0.09), Colors.white.withValues(alpha: 0)],
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24 * k, 22 * k, 24 * k, 26 * k),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (spec.note != null)
                Row(children: [
                  Icon(Icons.sync_rounded, size: 13 * k, color: AppColors.textSoft),
                  SizedBox(width: 6 * k),
                  Expanded(
                    child: Text(spec.note!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: AppColors.textSoft, fontSize: 12 * k, fontWeight: FontWeight.w600)),
                  ),
                ]),
              const Spacer(),
              Icon(spec.icon,
                  size: 56 * k, color: Color.lerp(AppColors.text, AppColors.accentBright, t)),
              SizedBox(height: 16 * k),
              Text(spec.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: AppColors.text,
                      fontSize: lerp(24, 30) * k,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      height: 1.1)),
              SizedBox(height: 6 * k),
              Text(spec.sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textSoft, fontSize: 15 * k, fontWeight: FontWeight.w500)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _BigClock extends StatefulWidget {
  const _BigClock({required this.k});
  final double k;

  @override
  State<_BigClock> createState() => _BigClockState();
}

class _BigClockState extends State<_BigClock> {
  static const _days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  static const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  late final Timer _timer;
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
  Widget build(BuildContext context) {
    final k = widget.k;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
      Text(hhmm(_now),
          style: TextStyle(
              color: AppColors.text,
              fontSize: 104 * k,
              fontWeight: FontWeight.w300,
              letterSpacing: -3,
              height: 0.95)),
      SizedBox(height: 2 * k),
      Text('${_days[_now.weekday - 1]}, ${_months[_now.month - 1]} ${_now.day}',
          style: TextStyle(color: AppColors.textSoft, fontSize: 24 * k, fontWeight: FontWeight.w300)),
    ]);
  }
}

class _KeyHints extends StatelessWidget {
  const _KeyHints({required this.k});
  final double k;

  @override
  Widget build(BuildContext context) {
    Widget hint(String key, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8 * k, vertical: 3 * k),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(key, style: TextStyle(color: AppColors.text, fontSize: 13 * k)),
          ),
          SizedBox(width: 8 * k),
          Text(label, style: TextStyle(color: AppColors.textDim, fontSize: 13 * k)),
        ]);
    return DefaultTextStyle.merge(
      style: const TextStyle(fontWeight: FontWeight.w600),
      child: Wrap(spacing: 26 * k, runSpacing: 8, children: [
        hint('Enter', 'Open'),
        hint('◀ ▶', 'Move'),
        hint('Ctrl F', 'Search'),
      ]),
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
