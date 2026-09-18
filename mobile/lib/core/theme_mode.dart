import 'package:flutter/material.dart';

/// The user's explicit light/dark choice from Profile. Starts at
/// [ThemeMode.light] — the Figma kit this app matches only has a light
/// surface designed, so following the device by default (the old
/// [ThemeMode.system]) silently diverged from it on any phone set to dark.
/// In-memory only — there's no local persistence layer yet (see
/// [demoModeEnabled] for the same caveat), so this resets on a cold restart.
final appThemeMode = ValueNotifier<ThemeMode>(ThemeMode.light);
