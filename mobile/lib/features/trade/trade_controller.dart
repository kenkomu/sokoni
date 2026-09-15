import 'package:flutter/foundation.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/ws/market_stream.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

enum StreamStatus { connecting, live, gap, disconnected }

@immutable
class TradeState {
  const TradeState({
    required this.symbol,
    this.candles,
    this.trades,
    this.streamStatus = StreamStatus.connecting,
    this.loading = false,
    this.error,
  });

  final String symbol;
  final List<Candle>? candles;
  final List<MarketTrade>? trades;
  final StreamStatus streamStatus;
  final bool loading;
  final String? error;

  TradeState copyWith({
    List<Candle>? candles,
    List<MarketTrade>? trades,
    StreamStatus? streamStatus,
    bool? loading,
    String? error,
    bool clearError = false,
  }) => TradeState(
    symbol: symbol,
    candles: candles ?? this.candles,
    trades: trades ?? this.trades,
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

  Future<void> loadInitial() async {
    _set(_state.copyWith(loading: true, clearError: true));
    try {
      final candles = await _api.candles(symbol: _state.symbol);
      final trades = await _api.recentTrades(symbol: _state.symbol);
      _set(_state.copyWith(candles: candles, trades: trades, loading: false));
    } catch (e) {
      _set(_state.copyWith(loading: false, error: describeFailure(e)));
    }
  }

  void subscribeLive() {
    _stream.events.listen(_onEvent);
    _stream.connect();
    _stream.subscribe([
      'candles:${_state.symbol}:60',
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
