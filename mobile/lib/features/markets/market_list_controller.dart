import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/market_summary.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class MarketListState {
  const MarketListState({this.summaries, this.loading = false, this.error});

  /// Null until the first load completes (successfully or not).
  final List<MarketSummary>? summaries;
  final bool loading;
  final String? error;

  MarketListState copyWith({
    List<MarketSummary>? summaries,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => MarketListState(
    summaries: summaries ?? this.summaries,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Every market plus its latest candle — the same [MarketSummary] shape Home
/// uses, so a price/change shown here and on Home never disagree.
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
      final summaries = await fetchMarketSummaries(_api);
      _set(MarketListState(summaries: summaries, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }
}
