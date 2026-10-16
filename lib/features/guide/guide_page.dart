import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../data/repository.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/paged_items.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../live/live_page.dart' show showProgrammeDialog;

const _pxPerMinute = 4.0;
const _rowHeight = 56.0;
const _channelWidth = 220.0;
const _headerHeight = 36.0;

/// Electronic programme guide: channels down, time across.
///
/// Rows are virtualised vertically; horizontally there is one shared offset
/// and each row only builds the programmes intersecting the viewport, so the
/// grid stays smooth with thousands of channels and a full day of data.
class GuidePage extends ConsumerStatefulWidget {
  const GuidePage({super.key, required this.source});
  final Source source;

  @override
  ConsumerState<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends ConsumerState<GuidePage> {
  late DateTime _day = _startOfDay(DateTime.now());
  int? _categoryId;
  List<Category> _cats = const [];
  bool _favoritesOnly = false;
  PagedItems? _items;
  final _offset = ValueNotifier<double>(0);
  final _vScroll = ScrollController();
  final _programmes = <String, List<Programme>>{};
  final _requested = <String>{};
  Timer? _tick;
  double _viewport = 800;

  Repository get _repo => ref.read(repositoryProvider);

  String _text = '';

  static DateTime _startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

  ItemQuery get _query => ItemQuery(
        kind: ItemKind.live,
        sourceId: widget.source.id,
        categoryId: _categoryId,
        favoritesOnly: _favoritesOnly,
        text: _text,
      );

  @override
  void initState() {
    super.initState();
    _loadCats();
    _rebuild();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToNow());
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(GuidePage old) {
    super.didUpdateWidget(old);
    if (old.source.id != widget.source.id) {
      _categoryId = null;
      _loadCats();
      _rebuild();
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _items?.dispose();
    _offset.dispose();
    _vScroll.dispose();
    super.dispose();
  }

  Future<void> _loadCats() async {
    final c = await _repo.categories(widget.source.id, ItemKind.live);
    if (mounted) setState(() => _cats = c);
  }

  void _rebuild() {
    _items?.dispose();
    _programmes.clear();
    _requested.clear();
    _items = PagedItems(_repo, _query, pageSize: 60)
      ..onPageLoaded = _loadProgrammes
      ..addListener(() => setState(() {}));
  }

  Future<void> _loadProgrammes(List<MediaItem> page) async {
    final ids = [
      for (final i in page)
        if (i.epgId != null && _requested.add(i.epgId!)) i.epgId!,
    ];
    if (ids.isEmpty) return;
    final m = await _repo.guide(
        widget.source.id, ids, _day, _day.add(const Duration(days: 1)));
    if (!mounted) return;
    setState(() => _programmes.addAll(m));
  }

  void _setDay(DateTime d) {
    setState(() {
      _day = d;
      _programmes.clear();
      _requested.clear();
    });
    _loadProgrammes(_items?.loadedItems.toList() ?? const []);
  }

  double get _maxOffset => math.max(0, 24 * 60 * _pxPerMinute - _viewport);

  void _scrollBy(double dx) =>
      _offset.value = (_offset.value + dx).clamp(0, _maxOffset);

  void _jumpToNow() {
    final now = DateTime.now();
    if (_startOfDay(now) != _day) _setDay(_startOfDay(now));
    final minutes = now.difference(_day).inMinutes - 30;
    _offset.value = (minutes * _pxPerMinute).clamp(0, _maxOffset);
  }

  Future<void> _openProgramme(MediaItem ch, Programme p) async {
    final now = DateTime.now();
    if (p.isLiveAt(now)) {
      final pl = await playableFor(_repo, ch);
      if (pl == null) return;
      await ref.read(appPlayerProvider).open(pl, zapQuery: _query, zapIndex: _items?.indexOf(ch));
      if (mounted) await PlayerPage.open(context, stopOnExit: false);
    } else {
      await showProgrammeDialog(context, p, ch.name);
    }
  }

  @override
  Widget build(BuildContext context) {
    final today = _startOfDay(DateTime.now());
    final days = [for (var i = -1; i <= 6; i++) today.add(Duration(days: i))];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 24, 4),
          child: PageHeader(
            eyebrow: "What's on",
            title: 'TV Guide',
            trailing: SizedBox(
              width: 300,
              child: GlassSearchField(
                hint: 'Search channels',
                onChanged: (v) {
                  setState(() => _text = v);
                  _rebuild();
                },
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 24, 8),
          child: Row(
            children: [
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int?>(
                  initialValue: _favoritesOnly ? -1 : _categoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.category_outlined, size: 18)),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('All channels')),
                    const DropdownMenuItem(value: -1, child: Text('Favorites')),
                    for (final c in _cats)
                      DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _favoritesOnly = v == -1;
                      _categoryId = v == -1 ? null : v;
                    });
                    _rebuild();
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final d in days)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(d == today
                              ? 'Today'
                              : d == today.subtract(const Duration(days: 1))
                                  ? 'Yesterday'
                                  : '${_weekday(d)} ${d.day}'),
                          selected: d == _day,
                          onSelected: (_) => _setDay(d),
                        ),
                      ),
                  ]),
                ),
              ),
              IconButton(
                tooltip: 'Earlier',
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _scrollBy(-120 * _pxPerMinute),
              ),
              FilledButton.tonal(onPressed: _jumpToNow, child: const Text('Now')),
              IconButton(
                tooltip: 'Later',
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _scrollBy(120 * _pxPerMinute),
              ),
            ],
          ),
        ),
        Expanded(
          child: GlassPanel(
            margin: const EdgeInsets.fromLTRB(12, 4, 24, 16),
            child: _grid(),
          ),
        ),
      ],
    );
  }

  static String _weekday(DateTime d) =>
      const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1];

  Widget _grid() {
    final items = _items!;
    final total = items.total;
    if (total == null) return const Center(child: CircularProgressIndicator());
    if (total == 0) {
      return EmptyState(
          icon: _text.isEmpty ? Icons.live_tv : Icons.search_off,
          title: _text.isEmpty ? 'No channels' : 'No channels match "$_text"');
    }
    if (widget.source.lastEpg == null) {
      return EmptyState(
        icon: Icons.calendar_view_week,
        title: 'No TV guide yet',
        message: widget.source.type == SourceType.xtream
            ? 'The guide downloads automatically after the playlist. Check Playlists for progress.'
            : 'Add an XMLTV guide URL to this playlist in Playlists to see programme listings.',
      );
    }
    return LayoutBuilder(builder: (context, c) {
      _viewport = c.maxWidth - _channelWidth;
      return Listener(
        // Shift + wheel, or horizontal trackpad scrolling, moves time.
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            final dx = e.scrollDelta.dx != 0
                ? e.scrollDelta.dx
                : (HardwareKeyboard.instance.isShiftPressed ? e.scrollDelta.dy : 0.0);
            if (dx != 0) {
              GestureBinding.instance.pointerSignalResolver.register(e, (_) => _scrollBy(dx));
            }
          }
        },
        child: GestureDetector(
          onHorizontalDragUpdate: (d) => _scrollBy(-d.delta.dx),
          child: Column(
            children: [
              SizedBox(
                height: _headerHeight,
                child: Row(children: [
                  const SizedBox(width: _channelWidth),
                  Expanded(
                    child: ValueListenableBuilder(
                      valueListenable: _offset,
                      builder: (_, off, _) => _TimeHeader(day: _day, offset: off),
                    ),
                  ),
                ]),
              ),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    Scrollbar(
                      controller: _vScroll,
                      child: ListView.builder(
                        controller: _vScroll,
                        itemCount: total,
                        itemExtent: _rowHeight,
                        itemBuilder: (_, i) {
                          final ch = items.itemAt(i);
                          if (ch == null) return const SizedBox(height: _rowHeight);
                          return _GuideRow(
                            channel: ch,
                            programmes: ch.epgId == null ? const [] : (_programmes[ch.epgId] ?? const []),
                            day: _day,
                            offset: _offset,
                            onTapChannel: () async {
                              final pl = await playableFor(_repo, ch);
                              if (pl == null) return;
                              await ref.read(appPlayerProvider).open(pl, zapQuery: _query, zapIndex: i);
                              if (context.mounted) await PlayerPage.open(context, stopOnExit: false);
                            },
                            onTapProgramme: (p) => _openProgramme(ch, p),
                          );
                        },
                      ),
                    ),
                    // "Now" line.
                    ValueListenableBuilder(
                      valueListenable: _offset,
                      builder: (_, off, _) {
                        final now = DateTime.now();
                        final x = now.difference(_day).inSeconds / 60 * _pxPerMinute - off;
                        if (x < 0 || x > _viewport) return const SizedBox.shrink();
                        return Positioned(
                          left: _channelWidth + x,
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: Container(width: 2, color: AppColors.live.withValues(alpha: 0.8)),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

class _TimeHeader extends StatelessWidget {
  const _TimeHeader({required this.day, required this.offset});
  final DateTime day;
  final double offset;

  @override
  Widget build(BuildContext context) {
    const slot = 30; // minutes
    return ClipRect(
      child: Stack(children: [
        for (var m = 0; m < 24 * 60; m += slot)
          if (m * _pxPerMinute - offset > -200 && m * _pxPerMinute - offset < 4000)
            Positioned(
              left: m * _pxPerMinute - offset,
              top: 0,
              bottom: 0,
              child: Container(
                width: slot * _pxPerMinute,
                padding: const EdgeInsets.only(left: 6),
                alignment: Alignment.centerLeft,
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: AppColors.border)),
                ),
                child: Text(hhmm(day.add(Duration(minutes: m))),
                    style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
              ),
            ),
      ]),
    );
  }
}

class _GuideRow extends StatelessWidget {
  const _GuideRow({
    required this.channel,
    required this.programmes,
    required this.day,
    required this.offset,
    required this.onTapChannel,
    required this.onTapProgramme,
  });

  final MediaItem channel;
  final List<Programme> programmes;
  final DateTime day;
  final ValueNotifier<double> offset;
  final VoidCallback onTapChannel;
  final ValueChanged<Programme> onTapProgramme;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: _channelWidth,
            child: InkWell(
              onTap: onTapChannel,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(children: [
                  NetLogo(url: channel.logo, name: channel.name, width: 44, height: 34),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(channel.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ]),
              ),
            ),
          ),
          Expanded(
            child: ClipRect(
              child: LayoutBuilder(
                builder: (_, c) => ValueListenableBuilder(
                  valueListenable: offset,
                  builder: (_, off, _) => _cells(off, c.maxWidth),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cells(double off, double width) {
    if (programmes.isEmpty) {
      return Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 12),
        child: Text(channel.epgId == null ? 'No guide data' : '',
            style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
      );
    }
    final now = DateTime.now();
    final dayEnd = day.add(const Duration(days: 1));
    final children = <Widget>[];
    for (final p in programmes) {
      final s = p.start.isBefore(day) ? day : p.start;
      final e = p.stop.isAfter(dayEnd) ? dayEnd : p.stop;
      final x = s.difference(day).inSeconds / 60 * _pxPerMinute - off;
      final w = e.difference(s).inSeconds / 60 * _pxPerMinute;
      if (x + w < 0 || x > width) continue;
      final live = p.isLiveAt(now);
      final past = p.stop.isBefore(now);
      // Keep the title visible when the cell starts left of the viewport.
      final textInset = x < 0 ? -x : 0.0;
      children.add(Positioned(
        left: x,
        width: math.max(w - 2, 1),
        top: 4,
        bottom: 4,
        child: Material(
          color: live
              ? AppColors.accent.withValues(alpha: 0.22)
              : (past ? AppColors.surface : AppColors.surfaceHigh),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(
                color: live ? AppColors.accent.withValues(alpha: 0.6) : AppColors.glassBorder),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onTapProgramme(p),
            child: Tooltip(
              message: '${p.title}\n${hhmm(p.start)} – ${hhmm(p.stop)}',
              waitDuration: const Duration(milliseconds: 700),
              child: Padding(
                padding: EdgeInsets.only(left: 8 + textInset, right: 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: live ? FontWeight.w600 : FontWeight.normal,
                            color: past ? AppColors.textDim : null)),
                    Text('${hhmm(p.start)} – ${hhmm(p.stop)}',
                        maxLines: 1,
                        style: const TextStyle(fontSize: 11, color: AppColors.textDim)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));
    }
    return Stack(children: children);
  }
}
