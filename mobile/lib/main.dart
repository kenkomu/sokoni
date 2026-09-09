import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/config.dart';
import 'design/theme.dart';

void main() {
  runApp(const ProviderScope(child: SokoniApp()));
}

class SokoniApp extends StatelessWidget {
  const SokoniApp({super.key});

  @override
  Widget build(BuildContext context) {
    final config = AppConfig.fromEnvironment();
    return MaterialApp(
      title: 'Sokoni',
      theme: SokoniTheme.light(),
      darkTheme: SokoniTheme.dark(),
      home: _Placeholder(config: config),
    );
  }
}

/// Replaced by the router in Phase 2. Kept honest: it shows which chain the
/// build is pinned to, so a testnet build can never be mistaken for mainnet.
class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.config});
  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Sokoni',
              style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(config.isMainnet ? 'Monad mainnet' : 'Monad testnet'),
          ],
        ),
      ),
    );
  }
}
