/// Why a [DownloadState.failed] happened. Sealed so callers can pattern-match
/// exhaustively instead of inspecting error strings.
sealed class DownloadFailure {
  const DownloadFailure();
}

final class DownloadNetworkFailure extends DownloadFailure {
  const DownloadNetworkFailure(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'DownloadNetworkFailure($message)';
}

final class DownloadChecksumMismatch extends DownloadFailure {
  const DownloadChecksumMismatch({
    required this.expectedSha256,
    required this.actualSha256,
  });
  final String expectedSha256;
  final String actualSha256;

  @override
  String toString() =>
      'DownloadChecksumMismatch(expected: $expectedSha256, actual: $actualSha256)';
}

final class DownloadCertificatePinningFailure extends DownloadFailure {
  const DownloadCertificatePinningFailure(this.host);
  final String host;

  @override
  String toString() => 'DownloadCertificatePinningFailure($host)';
}

final class DownloadCancelled extends DownloadFailure {
  const DownloadCancelled();

  @override
  String toString() => 'DownloadCancelled()';
}

final class DownloadIncomplete extends DownloadFailure {
  const DownloadIncomplete({required this.bytesReceived, required this.totalBytes});
  final int bytesReceived;
  final int totalBytes;

  @override
  String toString() => 'DownloadIncomplete($bytesReceived/$totalBytes)';
}

final class DownloadUnknownFailure extends DownloadFailure {
  const DownloadUnknownFailure(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;

  @override
  String toString() => 'DownloadUnknownFailure($error)';
}
