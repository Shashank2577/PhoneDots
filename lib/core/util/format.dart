String formatBytes(int bytes) {
  // Thresholds sit where rounding would print "1000 KB", so it moves up a unit.
  if (bytes >= 999500 * 1000) return '${(bytes / 1e9).toStringAsFixed(1)} GB';
  if (bytes >= 999500) return '${(bytes / 1e6).round()} MB';
  if (bytes >= 1000) return '${(bytes / 1e3).round()} KB';
  return '$bytes B';
}

String formatDuration(double seconds) {
  if (!seconds.isFinite || seconds < 0) seconds = 0;
  final s = seconds.round();
  final m = s ~/ 60;
  final r = s % 60;
  return '$m:${r.toString().padLeft(2, '0')}';
}

String formatMs(int ms) => ms < 1000 ? '$ms ms' : '${(ms / 1000).toStringAsFixed(1)} s';

String timeAgo(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes}m ago';
  if (d.inDays < 1) return '${d.inHours}h ago';
  if (d.inDays < 7) return '${d.inDays}d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}
