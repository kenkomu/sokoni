import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class MarketListState {
  const MarketListState({this.markets, this.loading = false, this.error});

  /// Null until the first load completes (successfully or not).
  final List<MarketInfo>? markets;
  final bool loading;
  final String? error;

  MarketListState copyWith({
    List<MarketInfo>? markets,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => MarketListState(
    markets: markets ?? this.markets,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Static market metadata only — symbol, tick size, min qty. Live prices are
/// the trade screen's job (one market at a time); this screen just needs to
/// be a fast, simple list to tap into one.
class MarketListController extends ChangeNotifier {
  MarketListController({required AppConfig config, SokoniApi? api})
    : _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final SokoniApi _api;

  MarketListState _state = const MarketListState();
  MarketListState get state => _state;
  bool _disposed = false;

  void _set(MarketListState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> load() async {
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final markets = await _api.markets();
      _set(MarketListState(markets: markets, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }
}
