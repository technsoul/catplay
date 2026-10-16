import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../../core/models.dart';
import '../../core/platform.dart';
import '../../downloads/download_button.dart';
import '../../downloads/downloads.dart';
import '../../player/app_player.dart';
import '../../player/player_view.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Movies and episodes saved for offline viewing.
class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tasks = ref.watch(downloadsProvider);
    final active = tasks.where((t) => t.status != DownloadStatus.done).toList();
    final done = tasks.where((t) => t.status == DownloadStatus.done).toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final used = done.fold<int>(0, (n, t) => n + t.received);

    return ListView(
      padding: context.isCompact
          ? const EdgeInsets.fromLTRB(12, 12, 12, 24)
          : const EdgeInsets.fromLTRB(16, 4, 24, 24),
      children: [
        PageHeader(
          eyebrow: done.isEmpty
              ? 'Movies and episodes saved to watch offline'
              : '${done.length} saved · ${formatBytes(used)}',
          title: 'Downloads',
          trailing: !isDesktop ? null : OutlinedButton.icon(
            onPressed: () => revealInFolder(ref.read(appPathsProvider).downloads),
            icon: const Icon(Icons.folder_open_rounded),
            label: const Text('Open folder'),
          ),
        ),
        const SizedBox(height: 20),
        if (tasks.isEmpty)
          const EmptyState(
            icon: Icons.download_rounded,
            title: 'Nothing downloaded yet',
            message: 'Use the download button on a movie or episode to save it to this device '
                'and watch it without an internet connection.',
          ),
        if (active.isNotEmpty) ...[
          const SectionTitle('In progress'),
          for (final (i, t) in active.indexed) ...[
            _DownloadTile(task: t).enter(i + 1),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 12),
        ],
        if (done.isNotEmpty) ...[
          const SectionTitle('Ready to watch'),
          for (final (i, t) in done.indexed) ...[
            _DownloadTile(task: t).enter(active.length + i + 1),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }
}

class _DownloadTile extends ConsumerWidget {
  const _DownloadTile({required this.task});
  final DownloadTask task;

  Future<void> _play(BuildContext context, WidgetRef ref) async {
    final t = task;
    final resume = await ref.read(repositoryProvider).resumePosition(t.sourceId, t.key);
    await ref.read(appPlayerProvider).open(Playable(
          sourceId: t.sourceId,
          key: t.key,
          kind: t.kind,
          title: t.title,
          subtitle: t.subtitle,
          url: t.path,
          logo: t.logo,
          resumeFrom: resume,
        ));
    if (context.mounted) await PlayerPage.open(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = task;
    final manager = ref.read(downloadsProvider.notifier);
    final done = t.status == DownloadStatus.done;
    final statusText = switch (t.status) {
      DownloadStatus.queued => 'Waiting…',
      DownloadStatus.downloading => [
          t.total != null
              ? '${formatBytes(t.received)} of ${formatBytes(t.total!)}'
              : formatBytes(t.received),
          if (t.speed > 0) '${formatBytes(t.speed)}/s',
        ].join(' · '),
      DownloadStatus.paused => 'Paused · ${formatBytes(t.received)}'
          '${t.total != null ? ' of ${formatBytes(t.total!)}' : ''}',
      DownloadStatus.failed => t.error ?? 'Failed',
      DownloadStatus.done => formatBytes(t.received),
    };

    final compact = context.isCompact;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.card),
        onTap: done ? () => _play(context, ref) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            NetLogo(
              url: t.logo,
              name: t.subtitle ?? t.title,
              width: t.kind == ItemKind.movie ? (compact ? 48 : 60) : (compact ? 96 : 140),
              height: compact ? (t.kind == ItemKind.movie ? 72 : 54) : 84,
              fit: BoxFit.cover,
            ),
            SizedBox(width: compact ? 10 : 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (t.subtitle != null)
                  Text(t.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppColors.textDim, fontSize: 12)),
                Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                if (!done) ...[
                  LinearProgressIndicator(
                    value: t.status == DownloadStatus.queued ? null : (t.fraction ?? 0),
                    minHeight: 3,
                    borderRadius: BorderRadius.circular(2),
                    color: t.status == DownloadStatus.failed
                        ? AppColors.live
                        : t.status == DownloadStatus.paused
                            ? AppColors.warning
                            : null,
                  ),
                  const SizedBox(height: 6),
                ],
                Text(statusText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: t.status == DownloadStatus.failed ? AppColors.live : AppColors.textDim,
                        fontSize: 12)),
              ]),
            ),
            SizedBox(width: compact ? 0 : 8),
            if (done)
              IconButton(
                tooltip: 'Play',
                icon: const Icon(Icons.play_circle_outline, size: 30),
                onPressed: () => _play(context, ref),
              )
            else if (t.isActive)
              IconButton(
                tooltip: 'Pause',
                icon: const Icon(Icons.pause_rounded),
                onPressed: () => manager.pause(t.id),
              )
            else
              IconButton(
                tooltip: t.status == DownloadStatus.failed ? 'Retry' : 'Resume',
                icon: Icon(t.status == DownloadStatus.failed ? Icons.refresh_rounded : Icons.play_arrow_rounded),
                onPressed: () => manager.resume(t.id),
              ),
            if (done && isDesktop)
              IconButton(
                tooltip: 'Show in folder',
                icon: const Icon(Icons.folder_open_rounded),
                onPressed: () => revealInFolder(t.path),
              ),
            IconButton(
              tooltip: done ? 'Delete file' : 'Cancel download',
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () async {
                if (!done || await confirmDeleteDownload(context, t.title)) {
                  await manager.remove(t.id);
                }
              },
            ),
          ]),
        ),
      ),
    );
  }
}
