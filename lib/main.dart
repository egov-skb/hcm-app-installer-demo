import 'dart:io';

import 'package:flutter/material.dart';
import 'package:digit_installer/digit_installer.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'demo_server.dart';
import 'update_config.dart';

void main() {
  runApp(const ShowcaseApp());
}

class ShowcaseApp extends StatelessWidget {
  const ShowcaseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'digit_installer showcase',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ShowcasePage(),
    );
  }
}

class ShowcasePage extends StatefulWidget {
  const ShowcasePage({super.key});

  @override
  State<ShowcasePage> createState() => _ShowcasePageState();
}

class _ShowcasePageState extends State<ShowcasePage> {
  PackageInfo? _packageInfo;
  DigitInstaller? _installer;
  DemoUpdateServer? _demoServer;
  UpdateState _state = const UpdateIdle();
  bool _checkingExistingDownload = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final info = await PackageInfo.fromPlatform();

    final Uri manifestUrl;
    if (isGithubReleaseHostConfigured) {
      manifestUrl = githubManifestUrl;
    } else {
      final server = DemoUpdateServer();
      await server.start();
      _demoServer = server;
      manifestUrl = server.manifestUrl;
    }

    final installer = DigitInstaller(
      DigitInstallerConfig(
        manifestUrl: manifestUrl,
        headersBuilder: githubToken.isEmpty
            ? null
            : () async => {'Authorization': 'Bearer $githubToken'},
        // The install always kills this app's process — see
        // DigitInstallerConfig.reopenAfterInstall — so relaunch afterward
        // instead of leaving the user on the home screen.
        reopenAfterInstall: true,
      ),
    );
    installer.updates.listen((state) async {
      if (mounted) setState(() => _state = state);
      if (state is UpdateInstalled) _deleteDownloadedApk(installer);
      if (state is UpdateAvailable) {
        await _skipDownloadIfAlreadyPresent(installer, state.manifest);
      }
    });

    if (!mounted) return;
    setState(() {
      _packageInfo = info;
      _installer = installer;
    });
  }

  @override
  void dispose() {
    _installer?.dispose();
    _demoServer?.stop();
    super.dispose();
  }

  /// `digit_installer` never deletes the downloaded APK on its own (see
  /// [DigitInstaller.lastFilePath]) — a multi-hundred-MB file would otherwise
  /// sit in app storage indefinitely after every successful update.
  Future<void> _deleteDownloadedApk(DigitInstaller installer) async {
    final path = installer.lastFilePath;
    if (path == null) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('Failed to delete downloaded APK at $path: $e');
    }
  }

  /// A previous [DigitInstaller.download] may have already fetched and
  /// verified this exact manifest's file without a follow-up [install] —
  /// e.g. the app was closed before the user tapped Install. When that's
  /// the case, skip showing a "Download" button entirely: kick off
  /// [DigitInstaller.download] right away (it detects the match and skips
  /// the network transfer) so the UI moves straight to "Install" instead.
  Future<void> _skipDownloadIfAlreadyPresent(
    DigitInstaller installer,
    UpdateManifest manifest,
  ) async {
    setState(() => _checkingExistingDownload = true);
    final alreadyDownloaded = await installer.isDownloaded(manifest);
    if (!mounted) return;
    setState(() => _checkingExistingDownload = false);
    if (alreadyDownloaded) installer.download();
  }

  @override
  Widget build(BuildContext context) {
    final info = _packageInfo;
    final installer = _installer;

    return Scaffold(
      body: Center(
        child: info == null || installer == null
            ? const CircularProgressIndicator()
            : SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  // Explicit gaps rather than `Column.spacing`, which needs
                  // Flutter 3.27+ (this project targets 3.22.2).
                  children: [
                    Text(
                      'Digit Installer Workspace',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'A self-hosted APK auto-updater for Flutter, showcased right here.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 48),
                    Text(
                      'Sample text for the version 1.0.0 release, which is the first release of this app.',
                      style: Theme.of(context).textTheme.titleSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Current Version ${info.version} (Build ${info.buildNumber})',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 48),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.system_update_alt,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'Update',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              Center(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 250),
                                  child: _StateView(
                                    key: ValueKey((
                                      _state.runtimeType,
                                      _checkingExistingDownload,
                                    )),
                                    state: _state,
                                    installer: installer,
                                    currentInfo: info,
                                    checkingExistingDownload:
                                        _checkingExistingDownload,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _StateView extends StatelessWidget {
  const _StateView({
    super.key,
    required this.state,
    required this.installer,
    required this.currentInfo,
    required this.checkingExistingDownload,
  });

  final UpdateState state;
  final DigitInstaller installer;
  final PackageInfo currentInfo;

  /// True while checking whether [UpdateAvailable]'s manifest is already
  /// downloaded on disk — see `_skipDownloadIfAlreadyPresent`.
  final bool checkingExistingDownload;

  void _checkForUpdate() => installer.checkForUpdate(
        currentVersionCode: int.tryParse(currentInfo.buildNumber) ?? 1,
        currentVersion: currentInfo.version,
      );

  @override
  Widget build(BuildContext context) {
    final success = Colors.green.shade600;
    return switch (state) {
      UpdateIdle() => ElevatedButton.icon(
          onPressed: _checkForUpdate,
          icon: const Icon(Icons.system_update),
          label: const Text('Check for update'),
        ),
      UpdateChecking() => const _StatusRow(
          spinner: true,
          label: 'Checking for updates…',
        ),
      UpdateUpToDate() => _TerminalStateView(
          icon: Icons.check_circle,
          color: success,
          label: 'Up to date',
          onCheckAgain: _checkForUpdate,
        ),
      UpdateAvailable(:final manifest) => checkingExistingDownload
          ? const _StatusRow(spinner: true, label: 'Checking local files…')
          : ElevatedButton.icon(
              onPressed: installer.download,
              icon: const Icon(Icons.cloud_download),
              label: Text('Download ${manifest.version}'),
            ),
      UpdateInitializing() =>
        const _StatusRow(spinner: true, label: 'Initializing…'),
      UpdateDownloading(:final progress) => _ProgressRow(
          fraction: progress.fraction,
          label:
              'Downloading… ${(progress.fraction * 100).toStringAsFixed(0)}%',
        ),
      UpdatePaused() => ElevatedButton.icon(
          onPressed: installer.download,
          icon: const Icon(Icons.play_arrow),
          label: const Text('Resume download'),
        ),
      UpdateVerifying() => const _StatusRow(spinner: true, label: 'Verifying…'),
      UpdateVerified() => ElevatedButton.icon(
          onPressed: installer.install,
          icon: const Icon(Icons.install_mobile),
          label: const Text('Install'),
        ),
      UpdateInstalling(:final fraction) => _ProgressRow(
          fraction: fraction,
          label: 'Installing… ${(fraction * 100).toStringAsFixed(0)}%',
        ),
      UpdateInstalled(:final installedVersion) => _TerminalStateView(
          icon: Icons.check_circle,
          color: success,
          label: 'Installed $installedVersion',
          onCheckAgain: _checkForUpdate,
        ),
      UpdateFailed(:final reason) => _FailureView(
          reason: reason,
          installer: installer,
          onRetry: _checkForUpdate,
        ),
    };
  }
}

/// [UpdateUpToDate] and [UpdateInstalled] are otherwise dead ends — with no
/// button, the only way back to [UpdateIdle] would be restarting the app.
class _TerminalStateView extends StatelessWidget {
  const _TerminalStateView({
    required this.icon,
    required this.color,
    required this.label,
    required this.onCheckAgain,
  });

  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onCheckAgain;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatusRow(icon: icon, color: color, label: label),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: onCheckAgain,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check again'),
        ),
      ],
    );
  }
}

/// Icon (or spinner) + label pair used for the non-actionable states —
/// keeps their layout consistent instead of each being a bare [Text].
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    this.icon,
    this.spinner = false,
    this.color,
    required this.label,
  });

  final IconData? icon;
  final bool spinner;
  final Color? color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (spinner)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (icon != null)
          Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}

class _ProgressRow extends StatelessWidget {
  const _ProgressRow({required this.fraction, required this.label});

  final double fraction;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: fraction, minHeight: 6),
        ),
        const SizedBox(height: 8),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({
    required this.reason,
    required this.installer,
    required this.onRetry,
  });

  final UpdateFailure reason;
  final DigitInstaller installer;
  final VoidCallback onRetry;

  /// Human-readable message per failure kind — pattern-matched exhaustively
  /// so a new [UpdateFailure] variant fails to compile here instead of
  /// silently falling back to a raw `toString()`.
  String _message(UpdateFailure reason) => switch (reason) {
        NetworkFailure(:final message) => 'Network error: $message',
        ManifestParseFailure() => 'The update manifest was malformed.',
        ChecksumMismatch() => 'Downloaded file failed checksum verification.',
        SignatureMismatch() =>
          "Downloaded APK's signing certificate didn't match.",
        CertificatePinningFailure(:final host) =>
          'TLS certificate for $host did not match the pinned certificate.',
        UserCancelled() => 'Cancelled.',
        InstallUnknownAppsNotPermitted() =>
          'Installing unknown apps isn\'t permitted for this app yet.',
        UnsupportedPlatform(:final operation, :final platform) =>
          '$operation isn\'t supported on $platform.',
        InstallerError(:final message) => 'Install failed: $message',
        DownloadIncomplete(:final bytesReceived, :final totalBytes) =>
          'Download stopped early ($bytesReceived of $totalBytes bytes).',
        UnknownFailure(:final error) => 'Unexpected error: $error',
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.error_outline, color: colorScheme.error, size: 32),
        const SizedBox(height: 8),
        Text(
          _message(reason),
          style: TextStyle(color: colorScheme.error),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        if (reason is InstallUnknownAppsNotPermitted)
          OutlinedButton(
            onPressed: installer.openInstallUnknownAppsSettings,
            child: const Text('Open settings'),
          ),
        const SizedBox(height: 8),
        ElevatedButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    );
  }
}
