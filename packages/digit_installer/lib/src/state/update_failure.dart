/// Why an update lifecycle ended in [UpdateFailed]. Sealed so callers can
/// pattern-match exhaustively instead of inspecting error strings.
sealed class UpdateFailure {
  const UpdateFailure();
}

final class NetworkFailure extends UpdateFailure {
  const NetworkFailure(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'NetworkFailure($message)';
}

final class ManifestParseFailure extends UpdateFailure {
  const ManifestParseFailure(this.message);
  final String message;

  @override
  String toString() => 'ManifestParseFailure($message)';
}

final class ChecksumMismatch extends UpdateFailure {
  const ChecksumMismatch({required this.expectedSha256, required this.actualSha256});
  final String expectedSha256;
  final String actualSha256;

  @override
  String toString() => 'ChecksumMismatch(expected: $expectedSha256, actual: $actualSha256)';
}

final class SignatureMismatch extends UpdateFailure {
  const SignatureMismatch({required this.expectedSha256, required this.actualSha256});
  final String? expectedSha256;
  final String actualSha256;

  @override
  String toString() => 'SignatureMismatch(expected: $expectedSha256, actual: $actualSha256)';
}

final class CertificatePinningFailure extends UpdateFailure {
  const CertificatePinningFailure(this.host);
  final String host;

  @override
  String toString() => 'CertificatePinningFailure($host)';
}

final class UserCancelled extends UpdateFailure {
  const UserCancelled();

  @override
  String toString() => 'UserCancelled()';
}

/// The user hasn't granted "install unknown apps" for this app (API 26+).
/// Surfaced distinctly from a generic error so the host app can prompt the
/// user via [DigitInstaller.openInstallUnknownAppsSettings] rather than show
/// a cryptic install failure.
final class InstallUnknownAppsNotPermitted extends UpdateFailure {
  const InstallUnknownAppsNotPermitted();

  @override
  String toString() => 'InstallUnknownAppsNotPermitted()';
}

final class UnsupportedPlatform extends UpdateFailure {
  const UnsupportedPlatform({required this.platform, required this.operation});
  final String platform;
  final String operation;

  @override
  String toString() => 'UnsupportedPlatform($operation on $platform)';
}

final class InstallerError extends UpdateFailure {
  const InstallerError({this.nativeStatusCode, required this.message});
  final int? nativeStatusCode;
  final String message;

  @override
  String toString() => 'InstallerError($nativeStatusCode: $message)';
}

final class DownloadIncomplete extends UpdateFailure {
  const DownloadIncomplete({required this.bytesReceived, required this.totalBytes});
  final int bytesReceived;
  final int totalBytes;

  @override
  String toString() => 'DownloadIncomplete($bytesReceived/$totalBytes)';
}

final class UnknownFailure extends UpdateFailure {
  const UnknownFailure(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;

  @override
  String toString() => 'UnknownFailure($error)';
}
