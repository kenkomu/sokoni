import 'package:flutter/material.dart';

import 'core/config.dart';
import 'core/theme_mode.dart';
import 'design/theme.dart';
import 'features/onboarding/welcome_screen.dart';

void main() {
  runApp(SokoniApp(config: AppConfig.fromEnvironment()));
}

class SokoniApp extends StatelessWidget {
  const SokoniApp({required this.config, super.key});

  final AppConfig config;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder:
          (context, mode, _) => MaterialApp(
            title: 'Sokoni',
            debugShowCheckedModeBanner: false,
            theme: SokoniTheme.light(),
            darkTheme: SokoniTheme.dark(),
            themeMode: mode,
            home: WelcomeScreen(config: config),
          ),
    );
  }
}
