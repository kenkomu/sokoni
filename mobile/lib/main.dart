import 'package:flutter/material.dart';

import 'core/config.dart';
import 'design/theme.dart';
import 'features/onboarding/onboarding_screen.dart';

void main() {
  runApp(SokoniApp(config: AppConfig.fromEnvironment()));
}

class SokoniApp extends StatelessWidget {
  const SokoniApp({required this.config, super.key});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sokoni',
      debugShowCheckedModeBanner: false,
      theme: SokoniTheme.light(),
      darkTheme: SokoniTheme.dark(),
      home: OnboardingScreen(config: config),
    );
  }
}
