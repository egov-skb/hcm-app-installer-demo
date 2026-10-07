import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'update_config.dart';

/// Lists every release on the configured GitHub repo (not just the latest
/// one `digit_installer`'s own manifest check surfaces) via the public
/// GitHub REST API — a separate, read-only view into version history.
class ReleasesPage extends StatefulWidget {
  const ReleasesPage({super.key});

  @override
  State<ReleasesPage> createState() => _ReleasesPageState();
}

class _ReleasesPageState extends State<ReleasesPage> {
  late Future<List<_Release>> _releases = _fetchReleases();

  Future<List<_Release>> _fetchReleases() async {
    final response = await http.get(
      githubReleasesApiUrl,
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'digit_installer_showcase',
        if (githubToken.isNotEmpty) 'Authorization': 'Bearer $githubToken',
      },
    );
    if (response.statusCode != 200) {
      throw Exception(
          'GitHub API returned ${response.statusCode}: ${response.body}');
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .map((e) => _Release.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('All releases')),
      body: RefreshIndicator(
        onRefresh: () async => setState(() => _releases = _fetchReleases()),
        child: FutureBuilder<List<_Release>>(
          future: _releases,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('Failed to load releases:\n${snapshot.error}'),
                  ),
                ],
              );
            }
            final releases = snapshot.data!;
            if (releases.isEmpty) {
              return const Center(child: Text('No releases published yet.'));
            }
            return ListView.separated(
              itemCount: releases.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final r = releases[index];
                return ListTile(
                  title: Text(r.name.isNotEmpty ? r.name : r.tagName),
                  subtitle: Text('${r.tagName} • published ${r.publishedAt}'),
                  trailing: r.prerelease
                      ? const Chip(label: Text('pre-release'))
                      : (index == 0 ? const Chip(label: Text('latest')) : null),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _Release {
  const _Release(
      {required this.tagName,
      required this.name,
      required this.publishedAt,
      required this.prerelease});

  factory _Release.fromJson(Map<String, dynamic> json) => _Release(
        tagName: json['tag_name'] as String? ?? '',
        name: json['name'] as String? ?? '',
        publishedAt: json['published_at'] as String? ??
            json['created_at'] as String? ??
            'unknown',
        prerelease: json['prerelease'] as bool? ?? false,
      );

  final String tagName;
  final String name;
  final String publishedAt;
  final bool prerelease;
}
