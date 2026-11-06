import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'pages/record_page.dart';
import 'pages/library_page.dart';
import 'pages/chunks_page.dart';
import 'pages/chat_page.dart';
import 'pages/settings_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  static const _pages = <Widget>[
    RecordPage(),
    LibraryPage(),
    ChunksPage(),
    ChatPage(),
  ];

  @override
  Widget build(BuildContext context) {
    final onboarded = ref.watch(settingsProvider).valueOrNull;

    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.mic_none_rounded),
            selectedIcon: Icon(Icons.mic_rounded),
            label: '记录',
          ),
          NavigationDestination(
            icon: Icon(Icons.library_books_outlined),
            selectedIcon: Icon(Icons.library_books_rounded),
            label: '日志',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style_rounded),
            label: '词块',
          ),
          NavigationDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum_rounded),
            label: '复习',
          ),
        ],
      ),
      floatingActionButton: _index == 0
          ? null
          : FloatingActionButton.small(
              tooltip: '设置',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              ),
              child: const Icon(Icons.settings_outlined),
            ),
      appBar: AppBar(
        title: Text(
          switch (_index) {
            0 => 'Echo English',
            1 => '语音日志',
            2 => '词块本',
            _ => '情景复现',
          },
        ),
        actions: [
          if (onboarded != null && !onboarded.llmReady)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsPage()),
                ),
                icon: const Icon(Icons.key_outlined, size: 18),
                label: const Text('填 Key'),
              ),
            ),
          IconButton(
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
    );
  }
}
