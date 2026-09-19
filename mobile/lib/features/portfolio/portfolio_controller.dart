import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/demo_market_data.dart';
import '../../data/repositories/market_summary.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class PortfolioState {
  const PortfolioState({
    this.summaries,
    this.balances,
    this.loading = false,
    this.error,
  });

  final List<MarketSummary>? summaries;

  /// Null until a real balances fetch completes — distinct from an empty
  /// list, which means "fetched, holds nothing of any sponsored token".
  final List<AccountBalance>? balances;
  final bool loading;
  final String? error;

  PortfolioState copyWith({
    List<MarketSummary>? summaries,
    List<AccountBalance>? balances,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => PortfolioState(
    summaries: summaries ?? this.summaries,
    balances: balances ?? this.balances,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

class PortfolioController extends ChangeNotifier {
  PortfolioController({
    required AppConfig config,
    required this.accountAddress,
    SokoniApi? api,
  }) : _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl);

  final SokoniApi _api;

  /// Null for the debug preview account, which was never registered with
  /// the gateway and has no real balance to read.
  final String? accountAddress;

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
      _set(
        PortfolioState(
          summaries: demoMarketSummaries(),
          balances: const [],
          loading: false,
        ),
      );
      return;
    }
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final address = accountAddress;
      final results = await (
        fetchMarketSummaries(_api),
        address == null
            ? Future.value(const <AccountBalance>[])
            : _api.balances(address).then((b) => b.balances),
      ).wait;
      _set(
        PortfolioState(
          summaries: results.$1,
          balances: results.$2,
          loading: false,
        ),
      );
    } catch (e) {
      // (Future, Future).wait wraps either side's failure in a
      // ParallelWaitError rather than letting it propagate as-is —
      // describeFailure needs the original ApiException, not that wrapper,
      // to produce the same message a single-request failure would.
      final original =
          e is ParallelWaitError
              ? ((e.errors as (AsyncError?, AsyncError?)).$1?.error ??
                  (e.errors as (AsyncError?, AsyncError?)).$2?.error ??
                  e)
              : e;
      _set(_state.copyWith(loading: false, error: describeFailure(original)));
    }
  }
}
