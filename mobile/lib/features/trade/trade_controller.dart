import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../core/demo_mode.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/repositories/demo_market_data.dart';
import '../../data/ws/market_stream.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

enum StreamStatus { connecting, live, gap, disconnected }

@immutable
class TradeState {
  const TradeState({
    required this.symbol,
    this.candles,
    this.trades,
    this.candleLimit = 60,
    this.candleInterval = 60,
    this.streamStatus = StreamStatus.connecting,
    this.loading = false,
    this.error,
  });

  final String symbol;
  final List<Candle>? candles;
  final List<MarketTrade>? trades;

  /// How many buckets of [candleInterval] the REST snapshot asked for.
  final int candleLimit;

  /// Which bucket size, in seconds, is currently shown — one of
  /// gateway.candleIntervalsS (60/300/3600/86400), matching the trade
  /// screen's 1H/6H/24H/All tabs.
  final int candleInterval;
  final StreamStatus streamStatus;
  final bool loading;
  final String? error;

  TradeState copyWith({
    List<Candle>? candles,
    List<MarketTrade>? trades,
    int? candleLimit,
    int? candleInterval,
    StreamStatus? streamStatus,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => TradeState(
    symbol: symbol,
    candles: candles ?? this.candles,
    trades: trades ?? this.trades,
    candleLimit: candleLimit ?? this.candleLimit,
    candleInterval: candleInterval ?? this.candleInterval,
    streamStatus: streamStatus ?? this.streamStatus,
    loading: loading ?? this.loading,
    error: clearError ? null : (error ?? this.error),
  );
}

/// Drives one market's trade screen: an initial REST snapshot, then a live
/// WebSocket subscription that folds updates into the same state. A gap in
/// the stream's sequence numbers is recovered by re-fetching the REST
/// snapshot — the stream itself never resends history, only the next delta.
class TradeController extends ChangeNotifier {
  TradeController({
    required AppConfig config,
    required String symbol,
    SokoniApi? api,
    MarketStream? stream,
  }) : _api = api ?? SokoniApi(baseUrl: config.apiBaseUrl),
       _stream = stream ?? MarketStream(config.wsUrl),
       _state = TradeState(symbol: symbol);

  final SokoniApi _api;
  final MarketStream _stream;

  TradeState _state;
  TradeState get state => _state;
  bool _disposed = false;

  /// Whether [subscribeLive] has run. There is no unsubscribe on this
  /// gateway (see MarketStream's doc), so switching intervals never drops
  /// the old channel — it only adds the new one, and [_applyMessage] filters
  /// incoming candle pushes by channel so a stale interval's push can never
  /// overwrite the one currently shown.
  bool _streaming = false;

  void _set(TradeState next) {
    if (_disposed) return;
    _state = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    // A live subscription must not outlive the widget that reads its events.
    _stream.dispose();
    super.dispose();
  }

  Future<void> loadInitial({int? limit, int? interval}) async {
    final useLimit = limit ?? _state.candleLimit;
    final useInterval = interval ?? _state.candleInterval;
    final intervalChanged = useInterval != _state.candleInterval;
    _set(
      _state.copyWith(
        candleLimit: useLimit,
        candleInterval: useInterval,
        loading: true,
        clearError: true,
      ),
    );
    // A new interval needs its own channel — there is no unsubscribe, so
    // this only ever adds one, never swaps (see MarketStream's doc and
    // _streaming above).
    if (_streaming && intervalChanged) {
      _stream.subscribe(['candles:${_state.symbol}:$useInterval']);
    }
    if (demoModeEnabled.value) {
      // A fixed series, not the (currently empty) real REST snapshot — see
      // CLAUDE.md's Known gaps: the testnet markets have no real trades yet.
      final series = demoCandleSeries(_state.symbol);
      final candles =
          series.length <= useLimit
              ? series
              : series.sublist(series.length - useLimit);
      _set(
        _state.copyWith(
          candles: candles,
          trades: demoTrades(_state.symbol),
          streamStatus: StreamStatus.live,
          loading: false,
        ),
      );
      return;
    }
    try {
      final candles = await _api.candles(
        symbol: _state.symbol,
        interval: useInterval,
        limit: useLimit,
      );
      final trades = await _api.recentTrades(symbol: _state.symbol);
      _set(_state.copyWith(candles: candles, trades: trades, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }

  void subscribeLive() {
    // Demo candles/trades are static — there's nothing for a live socket to
    // deliver, and connecting anyway would just show "Disconnected" over
    // data that was never live in the first place.
    if (demoModeEnabled.value) return;
    _streaming = true;
    _stream.events.listen(_onEvent);
    _stream.connect();
    _stream.subscribe([
      'candles:${_state.symbol}:${_state.candleInterval}',
      'trades:${_state.symbol}',
    ]);
  }

  void _onEvent(MarketEvent event) {
    switch (event) {
      case MarketMessage(:final data):
        _applyMessage(data);
      case MarketGap():
        _set(_state.copyWith(streamStatus: StreamStatus.gap));
        // The stream only carries deltas; recovering from a missed one means
        // asking the gateway what the current state actually is.
        loadInitial();
      case MarketDisconnected():
        _set(_state.copyWith(streamStatus: StreamStatus.disconnected));
    }
  }

  void _applyMessage(Map<String, dynamic> envelope) {
    final type = envelope['type'] as String?;
    final data = envelope['data'] as Map<String, dynamic>?;
    if (data == null) return;

    if (type == 'candle') {
      // There is no unsubscribe, so a channel for an interval the user has
      // since tabbed away from keeps pushing — 'ch' is
      // "candles:<symbol>:<interval>", and only a push for the interval
      // actually on screen may touch state, or switching tabs back and
      // forth would show whichever interval's poll last happened to fire.
      final ch = envelope['ch'] as String?;
      if (ch != 'candles:${_state.symbol}:${_state.candleInterval}') return;
      final candle = Candle.fromJson(data);
      final candles = List<Candle>.from(_state.candles ?? const []);
      if (candles.isNotEmpty && candles.last.bucketTs == candle.bucketTs) {
        candles[candles.length - 1] = candle;
      } else {
        candles.add(candle);
      }
      _set(_state.copyWith(candles: candles, streamStatus: StreamStatus.live));
    } else if (type == 'trade') {
      final trade = MarketTrade.fromJson(data);
      final trades = <MarketTrade>[trade, ...?_state.trades];
      _set(_state.copyWith(trades: trades, streamStatus: StreamStatus.live));
    }
  }
}
