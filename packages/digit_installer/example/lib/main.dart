import 'package:flutter/material.dart';
import 'package:digit_installer/digit_installer.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'digit_installer example',
      theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple)),
      home: const UpdateDemoPage(),
    );
  }
}

class UpdateDemoPage extends StatefulWidget {
  const UpdateDemoPage({super.key});

  @override
  State<UpdateDemoPage> createState() => _UpdateDemoPageState();
}

class _UpdateDemoPageState extends State<UpdateDemoPage> {
  // Replace with your own GitHub Releases (or any other host's) manifest
  // URL — see the package README for the JSON shape expected here.
  final _installer = DigitInstaller(
    DigitInstallerConfig(
      manifestUrl: Uri.parse('https://github.com/your-org/your-app/releases/latest/download/manifest.json'),
    ),
  );

  UpdateState _state = const UpdateIdle();

  @override
  void initState() {
    super.initState();
    _installer.updates.listen((state) => setState(() => _state = state));
  }

  @override
  void dispose() {
    _installer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('digit_installer example')),
      body: Center(
        child: switch (_state) {
          UpdateIdle() => ElevatedButton(
            onPressed: () => _installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0'),
            child: const Text('Check for update'),
          ),
          UpdateChecking() => const CircularProgressIndicator(),
          UpdateUpToDate() => const Text('Up to date'),
          UpdateAvailable(:final manifest) => ElevatedButton(
            onPressed: _installer.download,
            child: Text('Download ${manifest.version}'),
          ),
          UpdateInitializing() => const Text('Initializing...'),
          UpdateDownloading(:final progress) => LinearProgressIndicator(value: progress.fraction),
          UpdatePaused() => ElevatedButton(onPressed: _installer.download, child: const Text('Resume')),
          UpdateVerifying() => const Text('Verifying...'),
          UpdateVerified() => ElevatedButton(onPressed: _installer.install, child: const Text('Install')),
          UpdateInstalling(:final fraction) => LinearProgressIndicator(value: fraction),
          UpdateInstalled(:final installedVersion) => Text('Installed $installedVersion'),
          UpdateFailed(:final reason) => Text('Failed: $reason'),
        },
      ),
    );
  }
}
