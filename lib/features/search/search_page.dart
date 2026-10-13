import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../vod/details.dart';

/// Instant full-text search across every playlist (SQLite FTS5).
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key, this.focusNode});
  final FocusNode? focusNode;

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  ItemKind? _kind;
  List<MediaItem> _results = const [];
  bool _searching = false;
  int _token = 0;
  Map<int, String> _sourceNames = const {};

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 160), _run);
  }

  Future<void> _run() async {
    final text = _controller.text.trim();
    final token = ++_token;
    if (text.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final repo = ref.read(repositoryProvider);
    final results = await repo.search(text, kind: _kind, limit: 300);
    final sources = await repo.sources();
    if (!mounted || token != _token) return; // a newer query superseded us
    setState(() {
      _results = results;
      _searching = false;
      _sourceNames = {for (final s in sources) s.id: s.name};
    });
  }

  @override
  Widget build(BuildContext context) {
    final multiSource = _sourceNames.length > 1;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            focusNode: widget.focusNode,
            autofocus: true,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Search channels, movies and series…',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _run();
                      },
                    ),
            ),
            onChanged: _onChanged,
            onSubmitted: (_) => _run(),
          ),
          const SizedBox(height: 12),
          Row(children: [
            for (final (label, kind) in const [
              ('All', null),
              ('Live TV', ItemKind.live),
              ('Movies', ItemKind.movie),
              ('Series', ItemKind.series),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(label),
                  selected: _kind == kind,
                  onSelected: (_) {
                    setState(() => _kind = kind);
                    _run();
                  },
                ),
              ),
            const Spacer(),
            if (_searching)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            else if (_controller.text.isNotEmpty)
              Text('${_results.length}${_results.length >= 300 ? '+' : ''} results',
                  style: const TextStyle(color: AppColors.textDim)),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _controller.text.isEmpty
                ? const EmptyState(
                    icon: Icons.search,
                    title: 'Search everything',
                    message: 'Type a few letters of a channel, movie or series name. '
                        'Every word is matched as a prefix, e.g. "bbc new" finds "BBC News HD".',
                  )
                : _results.isEmpty && !_searching
                    ? const EmptyState(icon: Icons.search_off, title: 'No matches')
                    : ListView.builder(
                        itemCount: _results.length,
                        itemExtent: 60,
                        itemBuilder: (_, i) {
                          final item = _results[i];
                          return ListTile(
                            leading: NetLogo(
                              url: item.logo,
                              name: item.name,
                              width: item.kind == ItemKind.live ? 52 : 30,
                              height: 42,
                              fit: item.kind == ItemKind.live ? BoxFit.contain : BoxFit.cover,
                            ),
                            title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              [
                                switch (item.kind) {
                                  ItemKind.live => 'Live TV',
                                  ItemKind.movie => 'Movie',
                                  ItemKind.series => 'Series',
                                },
                                ?item.year,
                                if (multiSource) ?_sourceNames[item.sourceId],
                              ].join(' · '),
                            ),
                            trailing: Icon(
                              item.kind == ItemKind.live ? Icons.play_arrow : Icons.chevron_right,
                            ),
                            onTap: () => openDetails(context, ref, item),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
