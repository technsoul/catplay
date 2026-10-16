import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'downloads.dart';

/// Download / progress / downloaded toggle for one movie or episode.
///
/// [onDownload] queues the item; the button then follows its progress.
class DownloadButton extends ConsumerWidget {
  const DownloadButton({
    super.key,
    required this.sourceId,
    required this.itemKey,
    required this.onDownload,
    this.outlined = true,
  });

  final int sourceId;
  final String itemKey;
  final VoidCallback onDownload;
  final bool outlined;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(downloadProvider('$sourceId|$itemKey'));
    final manager = ref.read(downloadsProvider.notifier);

    final (Widget icon, String tip, VoidCallback onPressed) = switch (t?.status) {
      null => (
          const Icon(Icons.download_rounded),
          'Download',
          () {
            onDownload();
            showInfo(context, 'Added to Downloads');
          },
        ),
      DownloadStatus.queued || DownloadStatus.downloading => (
          SizedBox(
            width: 20,
            height: 20,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(strokeWidth: 2.5, value: t!.fraction),
              const Icon(Icons.pause_rounded, size: 12),
            ]),
          ),
          t.status == DownloadStatus.queued
              ? 'Waiting to download — click to pause'
              : 'Downloading ${_percent(t)} — click to pause',
          () => manager.pause(t.id),
        ),
      DownloadStatus.paused || DownloadStatus.failed => (
          Icon(Icons.file_download_off_outlined,
              color: t!.status == DownloadStatus.failed ? AppColors.live : AppColors.warning),
          t.status == DownloadStatus.failed
              ? 'Download failed: ${t.error ?? 'unknown error'} — click to retry'
              : 'Paused at ${_percent(t)} — click to resume',
          () => manager.resume(t.id),
        ),
      DownloadStatus.done => (
          const Icon(Icons.download_done_rounded, color: AppColors.success),
          'Downloaded — click to delete the file',
          () async {
            if (await confirmDeleteDownload(context, t!.title)) await manager.remove(t.id);
          },
        ),
    };

    return outlined
        ? IconButton.outlined(tooltip: tip, icon: icon, onPressed: onPressed)
        : IconButton(tooltip: tip, icon: icon, onPressed: onPressed);
  }

  static String _percent(DownloadTask t) =>
      t.fraction == null ? formatBytes(t.received) : '${(t.fraction! * 100).toStringAsFixed(0)}%';
}

Future<bool> confirmDeleteDownload(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete download?'),
        content: Text('“$title” will be removed from this computer. You can still stream it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    ) ??
    false;
