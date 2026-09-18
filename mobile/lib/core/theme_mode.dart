import 'package:flutter/material.dart';

/// The user's explicit light/dark choice from Profile. Starts at
/// [ThemeMode.system] so the app follows the device until they override it.
/// In-memory only — there's no local persistence layer yet (see
/// [demoModeEnabled] for the same caveat), so this resets on a cold restart.
final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.system);
