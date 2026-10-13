import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../data/repository.dart';

/// Lazily pages a (potentially 100k-row) item list from the database.
///
/// Only pages that are actually scrolled into view are fetched, and pages far
/// from the viewport are evicted, so memory stays flat for huge playlists.
class PagedItems extends ChangeNotifier {
  PagedItems(this.repo, this.query, {this.pageSize = 100}) {
    _loadCount();
  }

  final Repository repo;
  final ItemQuery query;
  final int pageSize;

  int? _total;
  final _pages = <int, List<MediaItem>>{};
  final _loading = <int>{};
  int _generation = 0;
  bool _disposed = false;

  /// Called after each page load (e.g. to fetch EPG for those channels).
  void Function(List<MediaItem> page)? onPageLoaded;

  int? get total => _total;
  bool get isLoading => _total == null;

  Future<void> _loadCount() async {
    final gen = _generation;
    final n = await repo.countItems(query);
    if (_disposed || gen != _generation) return;
    _total = n;
    notifyListeners();
  }

  /// Returns the item at [index] if loaded; otherwise schedules its page.
  MediaItem? itemAt(int index) {
    final page = index ~/ pageSize;
    final list = _pages[page];
    if (list != null) {
      final i = index - page * pageSize;
      return i < list.length ? list[i] : null;
    }
    _load(page);
    return null;
  }

  Iterable<MediaItem> get loadedItems => _pages.values.expand((p) => p);

  Future<void> _load(int page) async {
    if (_loading.contains(page)) return;
    _loading.add(page);
    final gen = _generation;
    try {
      final items = await repo.items(query, offset: page * pageSize, limit: pageSize);
      if (_disposed || gen != _generation) return;
      _pages[page] = items;
      _evict(page);
      onPageLoaded?.call(items);
      notifyListeners();
    } catch (e) {
      debugPrint('page load failed: $e');
    } finally {
      _loading.remove(page);
    }
  }

  void _evict(int around) {
    if (_pages.length <= 12) return;
    final far = _pages.keys.where((p) => (p - around).abs() > 6).toList();
    for (final p in far) {
      _pages.remove(p);
    }
  }

  /// Re-reads everything (after imports or favorite changes).
  void refresh({bool keepItems = true}) {
    _generation++;
    final pages = _pages.keys.toList();
    if (!keepItems) {
      _pages.clear();
      _total = null;
    }
    _loading.clear();
    _loadCount();
    for (final p in pages) {
      _reload(p);
    }
    notifyListeners();
  }

  Future<void> _reload(int page) async {
    final gen = _generation;
    final items = await repo.items(query, offset: page * pageSize, limit: pageSize);
    if (_disposed || gen != _generation) return;
    _pages[page] = items;
    onPageLoaded?.call(items);
    notifyListeners();
  }

  /// Updates one item in place (e.g. favorite toggled) without a reload.
  void replace(MediaItem item) {
    for (final list in _pages.values) {
      final i = list.indexWhere((e) => e.id == item.id);
      if (i != -1) {
        list[i] = item;
        notifyListeners();
        return;
      }
    }
  }

  int? indexOf(MediaItem item) {
    for (final e in _pages.entries) {
      final i = e.value.indexWhere((x) => x.id == item.id);
      if (i != -1) return e.key * pageSize + i;
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
