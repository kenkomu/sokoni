/// Runtime configuration.
///
/// Values come from --dart-define so a build is pinned to an environment and
/// nothing sensitive is compiled into the default path.
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsUrl,
    required this.chainId,
    required this.relyingPartyId,
    this.walletConnectProjectId = '',
  });

  final String apiBaseUrl;
  final String wsUrl;
  final int chainId;

  /// From cloud.reown.com — free, but tied to a real account, so it's never
  /// compiled in as a default the way the other config here can be. Empty
  /// means "Connect Wallet" is disabled rather than crashing on an invalid
  /// id; see welcome_screen.dart.
  final String walletConnectProjectId;

  /// Domain the passkey is bound to.
  ///
  /// The platform will refuse to create or use a credential unless this domain
  /// serves a Digital Asset Links file naming this app's signing certificate.
  /// That binding is what stops another app from using our credentials, and it
  /// is also the first thing to check when registration fails on device.
  final String relyingPartyId;

  static const monadMainnet = 143;
  static const monadTestnet = 10143;

  factory AppConfig.fromEnvironment() => const AppConfig(
    apiBaseUrl: String.fromEnvironment(
      'SOKONI_API',
      defaultValue: 'http://10.0.2.2:8080', // Android emulator → host
    ),
    wsUrl: String.fromEnvironment(
      'SOKONI_WS',
      defaultValue: 'ws://10.0.2.2:8080/v1/stream',
    ),
    chainId: int.fromEnvironment('SOKONI_CHAIN_ID', defaultValue: monadTestnet),
    relyingPartyId: String.fromEnvironment(
      // sokoni.app is a parked domain nobody here owns, so it can never
      // serve a Digital Asset Links file — sokoni.bitshada.com is the real
      // deployment target this points at.
      'SOKONI_RP_ID',
      defaultValue: 'sokoni.bitshada.com',
    ),
    walletConnectProjectId: String.fromEnvironment('WALLETCONNECT_PROJECT_ID'),
  );

  bool get isMainnet => chainId == monadMainnet;
}
