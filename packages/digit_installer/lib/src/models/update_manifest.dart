/// Describes an available update. This is the JSON shape `digit_installer`
/// expects at [DigitInstallerConfig.manifestUrl] — hosting-agnostic (works
/// equally against a GitHub Releases asset, a custom backend, etc).
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    required this.versionCode,
    required this.downloadUrl,
    required this.sha256,
    this.signingCertSha256,
    this.size,
    this.releaseNotes,
    this.mandatory = false,
  });

  /// Human-readable version, e.g. `"1.4.0"`.
  final String version;

  /// Monotonically increasing build number, compared against the host app's
  /// current version code to decide whether an update is available.
  final int versionCode;

  final Uri downloadUrl;

  /// Expected SHA-256 of the downloaded APK, verified before install.
  final String sha256;

  /// Expected SHA-256 of the APK's signing certificate. When present, this is
  /// checked against the new APK (and optionally the currently-installed
  /// app) before a PackageInstaller session is created. Optional because not
  /// every deployment pins a signing certificate.
  final String? signingCertSha256;

  final int? size;

  final String? releaseNotes;

  final bool mandatory;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) => UpdateManifest(
    version: json['version'] as String,
    versionCode: json['versionCode'] as int,
    downloadUrl: Uri.parse(json['downloadUrl'] as String),
    sha256: json['sha256'] as String,
    signingCertSha256: json['signingCertSha256'] as String?,
    size: json['size'] as int?,
    releaseNotes: json['releaseNotes'] as String?,
    mandatory: json['mandatory'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'version': version,
    'versionCode': versionCode,
    'downloadUrl': downloadUrl.toString(),
    'sha256': sha256,
    if (signingCertSha256 != null) 'signingCertSha256': signingCertSha256,
    if (size != null) 'size': size,
    if (releaseNotes != null) 'releaseNotes': releaseNotes,
    'mandatory': mandatory,
  };
}
