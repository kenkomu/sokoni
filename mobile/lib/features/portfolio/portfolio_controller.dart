import 'package:decimal/decimal.dart';
import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/market_summary.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

@immutable
class PortfolioState {
  const PortfolioState({
    this.balances,
    this.activity,
    this.prices,
    this.loading = false,
    this.activityLoading = false,
    this.error,
    this.activityError,
  });

  /// Null until a real balances fetch completes — distinct from an empty
  /// list, which means "fetched, holds nothing of any sponsored token".
  final List<AccountBalance>? balances;
  final List<AccountActivity>? activity;

  /// Base symbol (e.g. "BTC", not "BTC-USDC") → last traded price in USDC,
  /// from whatever market quotes it. Null until fetched; a symbol simply
  /// absent from a fetched map means no market prices it, not "priced at
  /// zero" — [totalValueUsdc] treats those two cases differently on
  /// purpose, see its own doc.
  final Map<String, Decimal>? prices;
  final bool loading;
  final bool activityLoading;
  final String? error;
  final String? activityError;

  PortfolioState copyWith({
    List<AccountBalance>? balances,
    List<AccountActivity>? activity,
    Map<String, Decimal>? prices,
    bool? loading,
    bool? activityLoading,
    String? error,
    String? activityError,
    bool clearError = false,
    bool clearActivityError = false,
  }) => PortfolioState(
    balances: balances ?? this.balances,
    activity: activity ?? this.activity,
    prices: prices ?? this.prices,
    loading: loading ?? this.loading,
    activityLoading: activityLoading ?? this.activityLoading,
    error: clearError ? null : (error ?? this.error),
    activityError:
        clearActivityError ? null : (activityError ?? this.activityError),
  );
}

/// A stablecoin's own value is definitionally ~1 unit of itself in USDC
/// terms — there is no "SYMBOL-USDC" market to look one up on, unlike BTC
/// or MON. Kept separate from [PortfolioState.prices] (which only ever
/// holds a real traded price) rather than pre-seeding the map with these,
/// so a caller can still tell "genuinely priced by a market" from "priced
/// by definition" if that distinction ever matters.
const stableAt1Usdc = {'USDC', 'AUSD'};

/// The account's total value in USDC, and whether every held token
/// contributed to it. `allPriced: false` means the total is a
/// known-incomplete lower bound (some balance exists that [prices] has no
/// entry for) — the UI's job is to say "and more" rather than show a
/// number that looks complete but isn't; see portfolio_screen.dart's
/// _AccountCard.
(Decimal total, bool allPriced) totalValueUsdc(
  List<AccountBalance> balances,
  Map<String, Decimal> prices,
) {
  var total = Decimal.zero;
  var allPriced = true;
  for (final b in balances) {
    final amount = Decimal.parse(b.amount).shift(-b.token.decimals);
    if (stableAt1Usdc.contains(b.token.symbol)) {
      total += amount;
      continue;
    }
    final price = prices[b.token.symbol];
    if (price == null) {
      if (amount != Decimal.zero) allPriced = false;
      continue;
    }
    total += amount * price;
  }
  return (total, allPriced);
}

/// Portfolio loads this account's balances and its account-scoped activity.
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
      _set(const PortfolioState(balances: [], activity: [], loading: false));
      return;
    }
    _set(
      _state.copyWith(
        loading: true,
        activityLoading: true,
        clearError: true,
        clearActivityError: true,
      ),
    );
    await Future.wait([
      _loadBalances(address),
      _loadActivity(address),
      _loadPrices(),
    ]);
  }

  /// Best-effort: a price fetch failing leaves [PortfolioState.prices] null,
  /// which the UI already treats the same as "not fetched yet" — it never
  /// blocks balances or activity from showing, since those are the actual
  /// point of this screen and don't depend on pricing to be useful.
  Future<void> _loadPrices() async {
    try {
      final summaries = await fetchMarketSummaries(_api);
      final prices = <String, Decimal>{};
      for (final s in summaries) {
        final close = s.lastCandle?.close;
        if (close != null) prices[s.market.baseSymbol] = Decimal.parse(close);
      }
      _set(_state.copyWith(prices: prices));
    } catch (_) {
      // See doc above.
    }
  }

  Future<void> _loadBalances(String address) async {
    try {
      final balances = await _api.balances(address);
      _set(_state.copyWith(balances: balances.balances, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }

  Future<void> _loadActivity(String address) async {
    try {
      final activity = await _api.accountActivity(address, limit: 20);
      _set(_state.copyWith(activity: activity, activityLoading: false));
    } catch (e) {
      _set(
        _state.copyWith(
          activityLoading: false,
          activityError: describeFailure(e),
        ),
      );
    }
  }
}
