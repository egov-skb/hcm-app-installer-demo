/// A point-in-time snapshot of a download's progress.
class DownloadProgress {
  const DownloadProgress({
    required this.bytesReceived,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.chunksTotal,
    required this.chunksCompleted,
  });

  final int bytesReceived;
  final int totalBytes;
  final double bytesPerSecond;
  final int chunksTotal;
  final int chunksCompleted;

  double get fraction => totalBytes <= 0 ? 0 : bytesReceived / totalBytes;

  @override
  String toString() =>
      'DownloadProgress($bytesReceived/$totalBytes, '
      '${(fraction * 100).toStringAsFixed(1)}%)';
}
