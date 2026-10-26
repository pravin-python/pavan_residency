import 'package:flutter/material.dart';

import 'bulk_screen.dart';
import 'settings_screen.dart';
import 'single_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('પાવન રેસીડેન્સી — Receipt Mailer'),
      ),
      body: IndexedStack(
        index: _index,
        children: [
          const SingleScreen(),
          BulkScreen(onOpenSettings: () => setState(() => _index = 2)),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.receipt_long), label: 'Single'),
          NavigationDestination(
              icon: Icon(Icons.upload_file), label: 'Bulk'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}
