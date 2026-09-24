import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class PortfolioState {
  const PortfolioState({this.balances, this.loading = false, this.error});

  /// Null until a real balances fetch completes — distinct from an empty
  /// list, which means "fetched, holds nothing of any sponsored token".
  final List<AccountBalance>? balances;
  final bool loading;
  final String? error;

  PortfolioState copyWith({
    List<AccountBalance>? balances,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => PortfolioState(
    balances: balances ?? this.balances,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Portfolio asks one question — what does this account hold — so it makes
/// exactly one request. It used to also pull the whole market list, for a
/// copy of the Markets tab that no longer sits on this screen (see
/// _ExploreMarketsCard in portfolio_screen.dart).
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
    final address = accountAddress;
    if (address == null) {
      _set(const PortfolioState(balances: [], loading: false));
      return;
    }
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final balances = await _api.balances(address);
      _set(PortfolioState(balances: balances.balances, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }
}
