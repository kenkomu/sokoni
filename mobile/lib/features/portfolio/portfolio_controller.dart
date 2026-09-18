import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/demo_market_data.dart';
import '../../data/repositories/market_summary.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class PortfolioState {
  const PortfolioState({this.summaries, this.loading = false, this.error});

  final List<MarketSummary>? summaries;
  final bool loading;
  final String? error;

  PortfolioState copyWith({
    List<MarketSummary>? summaries,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => PortfolioState(
    summaries: summaries ?? this.summaries,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

class PortfolioController extends ChangeNotifier {
  PortfolioController({required AppConfig config, SokoniApi? api})
    : _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final SokoniApi _api;

  PortfolioState _state = const PortfolioState();
  PortfolioState get state => _state;
  bool _disposed = false;

  void _set(PortfolioState next) {
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
    if (demoModeEnabled.value) {
      _set(PortfolioState(summaries: demoMarketSummaries(), loading: false));
      return;
    }
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final summaries = await fetchMarketSummaries(_api);
      _set(PortfolioState(summaries: summaries, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }
}
