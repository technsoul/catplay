import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/image_cache.dart';
import '../../core/settings.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  int? _cacheBytes;
  late final _ua = TextEditingController(text: ref.read(settingsProvider).userAgent);

  @override
  void initState() {
    super.initState();
    CachedNetImage.cacheSize().then((b) {
      if (mounted) setState(() => _cacheBytes = b);
    });
  }

  @override
  void dispose() {
    _ua.dispose();
    super.dispose();
  }

  void _set(AppSettings Function(AppSettings) f) => ref.read(settingsProvider.notifier).update(f);

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(settingsProvider);
    final t = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('Settings', style: t.headlineSmall),
        const SizedBox(height: 20),
        _Section(title: 'Playback', children: [
          SwitchListTile(
            title: const Text('Hardware decoding'),
            subtitle: const Text('Uses the GPU (D3D11/DXVA2). Turn off if you see green or frozen video. Takes effect after restart.'),
            value: s.hardwareDecoding,
            onChanged: (v) => _set((x) => x.copyWith(hardwareDecoding: v)),
          ),
          _SliderTile(
            title: 'Network buffer',
            value: s.cacheSeconds.toDouble(),
            min: 5,
            max: 120,
            divisions: 23,
            label: '${s.cacheSeconds} s',
            subtitle: 'More buffer survives unstable connections but zaps slower. Takes effect after restart.',
            onChanged: (v) => _set((x) => x.copyWith(cacheSeconds: v.round())),
          ),
          ListTile(
            title: const Text('Xtream live stream format'),
            subtitle: const Text('MPEG-TS is the most compatible; HLS can work better through proxies'),
            trailing: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'ts', label: Text('MPEG-TS')),
                ButtonSegment(value: 'm3u8', label: Text('HLS')),
              ],
              selected: {s.liveFormat},
              onSelectionChanged: (v) => _set((x) => x.copyWith(liveFormat: v.first)),
            ),
          ),
          ListTile(
            title: const Text('User-Agent'),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                controller: _ua,
                decoration: const InputDecoration(hintText: 'Default'),
                onSubmitted: (v) => _set((x) => x.copyWith(userAgent: v.trim())),
                onTapOutside: (_) => _set((x) => x.copyWith(userAgent: _ua.text.trim())),
              ),
            ),
          ),
        ]),
        _Section(title: 'TV guide', children: [
          _SliderTile(
            title: 'Keep past programmes',
            value: s.epgPastHours.toDouble(),
            min: 0,
            max: 168,
            divisions: 14,
            label: '${s.epgPastHours} h',
            subtitle: 'Needed for catch-up. Fewer hours = smaller, faster guide.',
            onChanged: (v) => _set((x) => x.copyWith(epgPastHours: v.round())),
          ),
          _SliderTile(
            title: 'Load future days',
            value: s.epgFutureDays.toDouble(),
            min: 1,
            max: 14,
            divisions: 13,
            label: '${s.epgFutureDays} d',
            onChanged: (v) => _set((x) => x.copyWith(epgFutureDays: v.round())),
          ),
          _SliderTile(
            title: 'Refresh guide every',
            value: s.epgRefreshHours.toDouble(),
            min: 0,
            max: 48,
            divisions: 8,
            label: s.epgRefreshHours == 0 ? 'Off' : '${s.epgRefreshHours} h',
            onChanged: (v) => _set((x) => x.copyWith(epgRefreshHours: v.round())),
          ),
        ]),
        _Section(title: 'Playlists', children: [
          _SliderTile(
            title: 'Refresh playlists every',
            value: s.autoRefreshHours.toDouble(),
            min: 0,
            max: 168,
            divisions: 7,
            label: s.autoRefreshHours == 0 ? 'Off' : '${s.autoRefreshHours} h',
            subtitle: 'Checked when the app starts',
            onChanged: (v) => _set((x) => x.copyWith(autoRefreshHours: (v / 24).round() * 24)),
          ),
          SwitchListTile(
            title: const Text('Resume last channel on start'),
            value: s.autoplayLastChannel,
            onChanged: (v) => _set((x) => x.copyWith(autoplayLastChannel: v)),
          ),
        ]),
        _Section(title: 'Storage', children: [
          ListTile(
            title: const Text('Image cache'),
            subtitle: Text(_cacheBytes == null
                ? 'Calculating…'
                : '${(_cacheBytes! / 1048576).toStringAsFixed(1)} MB of logos and posters'),
            trailing: OutlinedButton(
              onPressed: () async {
                await CachedNetImage.clear();
                setState(() => _cacheBytes = 0);
                if (context.mounted) showInfo(context, 'Image cache cleared');
              },
              child: const Text('Clear'),
            ),
          ),
          ListTile(
            title: const Text('Watch history'),
            subtitle: const Text('Continue watching and recent channels'),
            trailing: OutlinedButton(
              onPressed: () async {
                await ref.read(repositoryProvider).clearHistory();
                if (context.mounted) showInfo(context, 'History cleared');
              },
              child: const Text('Clear'),
            ),
          ),
        ]),
        _Section(title: 'Keyboard shortcuts', children: const [
          _Shortcut('Space / K', 'Play / pause'),
          _Shortcut('F / F11 / double-click', 'Full screen'),
          _Shortcut('Esc', 'Exit full screen / close player'),
          _Shortcut('Page Up / Page Down, ← →', 'Previous / next channel (live)'),
          _Shortcut('← →', 'Seek 10 s (movies)'),
          _Shortcut('↑ ↓', 'Volume'),
          _Shortcut('M', 'Mute'),
          _Shortcut('Ctrl + F', 'Search'),
        ]),
        const SizedBox(height: 12),
        const Center(
          child: Text('CAT 1.0.0 · Playback by libmpv (media_kit)',
              style: TextStyle(color: AppColors.textDim, fontSize: 12)),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SectionTitle(title),
          Card(child: Column(children: children)),
        ]),
      );
}

class _SliderTile extends StatefulWidget {
  const _SliderTile({
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.label,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String label;
  final String? subtitle;
  final ValueChanged<double> onChanged;

  @override
  State<_SliderTile> createState() => _SliderTileState();
}

class _SliderTileState extends State<_SliderTile> {
  double? _drag;

  @override
  Widget build(BuildContext context) => ListTile(
        title: Text(widget.title),
        subtitle: widget.subtitle == null ? null : Text(widget.subtitle!),
        trailing: SizedBox(
          width: 320,
          child: Row(children: [
            Expanded(
              child: Slider(
                value: (_drag ?? widget.value).clamp(widget.min, widget.max),
                min: widget.min,
                max: widget.max,
                divisions: widget.divisions,
                onChanged: (v) => setState(() => _drag = v),
                onChangeEnd: (v) {
                  widget.onChanged(v);
                  setState(() => _drag = null);
                },
              ),
            ),
            SizedBox(width: 56, child: Text(widget.label, textAlign: TextAlign.right)),
          ]),
        ),
      );
}

class _Shortcut extends StatelessWidget {
  const _Shortcut(this.keys, this.action);
  final String keys;
  final String action;

  @override
  Widget build(BuildContext context) => ListTile(
        dense: true,
        title: Text(action),
        trailing: Text(keys, style: const TextStyle(color: AppColors.textDim)),
      );
}
