import 'package:flutter/foundation.dart';

/// Starred market symbols, shared between Markets and the coin detail
/// screen so tapping the star in one place is reflected in the other.
/// Session-only — resets on a cold restart, nothing persists it.
final favouriteSymbols = ValueNotifier<Set<String>>(<String>{});

void toggleFavourite(String symbol) {
  final next = Set<String>.of(favouriteSymbols.value);
  if (!next.remove(symbol)) next.add(symbol);
  favouriteSymbols.value = next;
}
