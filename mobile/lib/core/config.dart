/// Runtime configuration.
///
/// Values come from --dart-define so a build is pinned to an environment and
/// nothing sensitive is compiled into the default path.
class AppConfig {
  const AppConfig({
    required this.apiBaseUrl,
    required this.wsUrl,
    required this.chainId,
  });

  final String apiBaseUrl;
  final String wsUrl;
  final int chainId;

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
      );

  bool get isMainnet => chainId == monadMainnet;
}
