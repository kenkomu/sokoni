import 'package:flutter/foundation.dart';

/// Whether screens should show [demoMarketSummaries] instead of real gateway
/// data. Off by default, and only ever toggled from a [kDebugMode]-gated
/// switch in Profile — the underlying widgets don't need to know why their
/// data changed, only that [MarketSummary.sparkline] being non-null means
/// "this is demo data, label it".
final demoModeEnabled = ValueNotifier<bool>(false);
