import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../app/xtream.dart';
import '../../core/models.dart';
import '../../import/import_job.dart' show ImportScope;
import '../../import/import_service.dart';
import '../../parsers/xtream_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SourcesPage extends ConsumerWidget {
  const SourcesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(sourcesProvider).value ?? const [];
    final imports = ref.watch(importProvider);
    final active = ref.watch(activeSourceProvider);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 24, 24),
      children: [
        PageHeader(
          eyebrow: 'Xtream Codes logins and M3U playlists',
          title: 'Playlists',
          trailing: FilledButton.icon(
            onPressed: () => showSourceDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Add playlist'),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Playlists refresh automatically (see Settings); the TV guide refreshes separately.',
          style: TextStyle(color: AppColors.textDim),
        ),
        const SizedBox(height: 20),
        if (sources.isEmpty)
          const EmptyState(icon: Icons.playlist_add, title: 'No playlists yet'),
        for (final (i, s) in sources.indexed) ...[
          _SourceCard(source: s, status: imports[s.id], isActive: active?.id == s.id).enter(i + 1),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

class _SourceCard extends ConsumerWidget {
  const _SourceCard({required this.source, required this.status, required this.isActive});
  final Source source;
  final ImportStatus? status;
  final bool isActive;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = source;
    final st = status;
    final busy = st != null && !st.finished;
    final typeLabel = switch (s.type) {
      SourceType.xtream => 'Xtream Codes',
      SourceType.m3uUrl => 'M3U URL',
      SourceType.m3uFile => 'M3U file',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(s.type == SourceType.xtream ? Icons.dns_outlined : Icons.list_alt,
                  color: AppColors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(s.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      const Chip(
                        label: Text('Active'),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      ),
                    ],
                  ]),
                  Text('$typeLabel · ${_host(s.url)}',
                      style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                ]),
              ),
              if (!isActive)
                TextButton(
                  onPressed: () => ref
                      .read(settingsProvider.notifier)
                      .update((x) => x.copyWith(activeSourceId: s.id)),
                  child: const Text('Use'),
                ),
              IconButton(
                tooltip: 'Refresh playlist + guide',
                onPressed: busy ? null : () => ref.read(importProvider.notifier).enqueue(s.id),
                icon: const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'epg':
                      ref.read(importProvider.notifier).enqueue(s.id, scope: ImportScope.epg);
                    case 'edit':
                      await showSourceDialog(context, existing: s);
                    case 'delete':
                      await _delete(context, ref);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'epg', child: Text('Refresh TV guide only')),
                  const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ]),
            const SizedBox(height: 12),
            Wrap(spacing: 20, runSpacing: 6, children: [
              _stat(Icons.live_tv, '${formatCount(s.liveCount)} channels'),
              _stat(Icons.movie_outlined, '${formatCount(s.movieCount)} movies'),
              _stat(Icons.video_library_outlined, '${formatCount(s.seriesCount)} series'),
              _stat(Icons.update, 'Updated ${formatRelative(s.lastRefresh)}'),
              _stat(Icons.calendar_view_week,
                  s.lastEpg == null ? 'No TV guide' : 'Guide ${formatRelative(s.lastEpg)}'),
              if (s.expiresAt != null)
                _stat(Icons.event, 'Expires ${s.expiresAt!.toLocal().toString().split(' ').first}'),
              if (s.maxConnections != null)
                _stat(Icons.devices, '${s.maxConnections} connections'),
            ]),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: st.queued ? null : st.fraction, minHeight: 3),
              const SizedBox(height: 6),
              Text(st.queued ? 'Waiting for another import…' : st.message,
                  style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
            ] else if (st?.error != null || (s.status == 'error' && s.error != null)) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.error_outline, size: 16, color: AppColors.live),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(st?.error ?? s.error!,
                      style: const TextStyle(color: AppColors.live, fontSize: 12)),
                ),
              ]),
            ] else if (st?.finished == true) ...[
              const SizedBox(height: 12),
              Row(children: [
                const Icon(Icons.check_circle_outline, size: 16, color: AppColors.success),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(st!.message,
                      style: const TextStyle(color: AppColors.success, fontSize: 12)),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  static String _host(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.host.isEmpty) {
      final parts = url.split(RegExp(r'[\\/]'));
      return parts.isEmpty ? url : parts.last;
    }
    return u.host;
  }

  Widget _stat(IconData icon, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: AppColors.textDim),
        const SizedBox(width: 5),
        Text(text, style: const TextStyle(fontSize: 12, color: AppColors.textDim)),
      ]);

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text('“${source.name}” and its favorites, history and TV guide will be removed from this PC.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.live),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (ref.read(importProvider.notifier).isActive(source.id)) {
      if (context.mounted) showError(context, 'Wait for the current import to finish first.');
      return;
    }
    await ref.read(repositoryProvider).deleteSource(source.id);
    await ref.read(secretsProvider).delete(source.id);
    ref.invalidate(xtreamApiProvider(source.id));
  }
}

/// Add / edit a playlist.
Future<void> showSourceDialog(BuildContext context, {Source? existing}) =>
    showDialog(context: context, builder: (_) => _SourceDialog(existing: existing));

class _SourceDialog extends ConsumerStatefulWidget {
  const _SourceDialog({this.existing});
  final Source? existing;

  @override
  ConsumerState<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends ConsumerState<_SourceDialog> {
  late SourceType _type = widget.existing?.type ?? SourceType.xtream;
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _url = TextEditingController(text: widget.existing?.url);
  late final _user = TextEditingController(text: widget.existing?.username);
  final _pass = TextEditingController();
  late final _epg = TextEditingController(text: widget.existing?.epgUrl);
  late final _ua = TextEditingController(text: widget.existing?.userAgent);
  bool _busy = false;
  bool _showPass = false;
  bool _advanced = false;
  String? _error;

  bool get _editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    if (_editing && _type == SourceType.xtream) {
      ref.read(secretsProvider).password(widget.existing!.id).then((p) {
        if (mounted && p != null) _pass.text = p;
      });
    }
    _advanced = (widget.existing?.userAgent ?? '').isNotEmpty;
  }

  @override
  void dispose() {
    for (final c in [_name, _url, _user, _pass, _epg, _ua]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickFile() async {
    final f = await FilePicker.pickFile(
      dialogTitle: 'Choose an M3U playlist',
      type: FileType.custom,
      allowedExtensions: const ['m3u', 'm3u8', 'txt'],
    );
    if (f?.path != null) {
      _url.text = f!.path!;
      if (_name.text.isEmpty) _name.text = f.name.replaceAll(RegExp(r'\.(m3u8?|txt)$'), '');
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(repositoryProvider);
      var url = _url.text.trim();
      if (_type == SourceType.xtream) {
        url = XtreamApi.normalizeServer(url);
        // Check the login before saving so typos fail fast.
        final api = XtreamApi(server: url, username: _user.text.trim(), password: _pass.text);
        try {
          await api.authenticate();
        } finally {
          api.close();
        }
      } else if (_type == SourceType.m3uUrl &&
          !(url.startsWith('http://') || url.startsWith('https://'))) {
        url = 'http://$url';
      }
      final name = _name.text.trim().isEmpty
          ? (Uri.tryParse(url)?.host.isNotEmpty == true ? Uri.parse(url).host : 'My playlist')
          : _name.text.trim();

      int id;
      if (_editing) {
        id = widget.existing!.id;
        await repo.updateSource(id,
            name: name, url: url, username: _user.text.trim(), epgUrl: _epg.text, userAgent: _ua.text);
      } else {
        id = await repo.addSource(
            name: name, type: _type, url: url, username: _user.text.trim(), epgUrl: _epg.text, userAgent: _ua.text);
      }
      if (_type == SourceType.xtream) {
        await ref.read(secretsProvider).setPassword(id, _pass.text);
        ref.invalidate(xtreamApiProvider(id));
      }
      if (!_editing && ref.read(activeSourceProvider) == null) {
        await ref.read(settingsProvider.notifier).update((s) => s.copyWith(activeSourceId: id));
      }
      ref.read(importProvider.notifier).enqueue(id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? v) => (v == null || v.trim().isEmpty) ? 'Required' : null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? 'Edit playlist' : 'Add playlist'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!_editing) ...[
                  SegmentedButton<SourceType>(
                    segments: const [
                      ButtonSegment(value: SourceType.xtream, icon: Icon(Icons.dns_outlined), label: Text('Xtream Codes')),
                      ButtonSegment(value: SourceType.m3uUrl, icon: Icon(Icons.link), label: Text('M3U URL')),
                      ButtonSegment(value: SourceType.m3uFile, icon: Icon(Icons.folder_open), label: Text('M3U file')),
                    ],
                    selected: {_type},
                    onSelectionChanged: (s) => setState(() => _type = s.first),
                  ),
                  const SizedBox(height: 16),
                ],
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Name (optional)'),
                ),
                const SizedBox(height: 12),
                if (_type == SourceType.xtream) ...[
                  TextFormField(
                    controller: _url,
                    validator: _required,
                    decoration: const InputDecoration(
                        labelText: 'Server URL', hintText: 'http://example.com:8080'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _user,
                    validator: _required,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    validator: _required,
                    obscureText: !_showPass,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: 'Stored in the Windows Credential Manager',
                      suffixIcon: IconButton(
                        icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPass = !_showPass),
                      ),
                    ),
                  ),
                ] else if (_type == SourceType.m3uUrl)
                  TextFormField(
                    controller: _url,
                    validator: _required,
                    decoration: const InputDecoration(
                        labelText: 'Playlist URL', hintText: 'http://…/playlist.m3u'),
                  )
                else
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _url,
                        validator: _required,
                        decoration: const InputDecoration(labelText: 'Playlist file'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(onPressed: _pickFile, child: const Text('Browse…')),
                  ]),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _epg,
                  decoration: InputDecoration(
                    labelText: 'TV guide URL (XMLTV, optional)',
                    hintText: 'http://…/epg.xml.gz',
                    helperText: _type == SourceType.xtream
                        ? 'Leave empty to use the provider\'s guide'
                        : 'Leave empty to use the url-tvg from the playlist, if any',
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => setState(() => _advanced = !_advanced),
                    icon: Icon(_advanced ? Icons.expand_less : Icons.expand_more),
                    label: const Text('Advanced'),
                  ),
                ),
                if (_advanced)
                  TextFormField(
                    controller: _ua,
                    decoration: const InputDecoration(
                      labelText: 'User-Agent override',
                      helperText: 'Some providers only allow specific players',
                    ),
                  ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: AppColors.live)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(_editing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
