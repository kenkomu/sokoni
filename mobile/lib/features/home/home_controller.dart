import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/demo_market_data.dart';
import '../../data/repositories/market_summary.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class HomeState {
  const HomeState({this.summaries, this.loading = false, this.error});

  final List<MarketSummary>? summaries;
  final bool loading;
  final String? error;

  HomeState copyWith({
    List<MarketSummary>? summaries,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => HomeState(
    summaries: summaries ?? this.summaries,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

class HomeController extends ChangeNotifier {
  HomeController({required AppConfig config, SokoniApi? api})
    : _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final SokoniApi _api;

  HomeState _state = const HomeState();
  HomeState get state => _state;
  bool _disposed = false;

  void _set(HomeState next) {
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
      _set(HomeState(summaries: demoMarketSummaries(), loading: false));
      return;
    }
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final summaries = await fetchMarketSummaries(_api);
      _set(HomeState(summaries: summaries, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }
}
