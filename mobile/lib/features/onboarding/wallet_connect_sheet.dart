import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reown_core/reown_core.dart';
import 'package:reown_sign/reown_sign.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../../data/wallet_connect/wallet_connect_signer.dart';
import '../../design/app_shell.dart';
import 'mera_controller.dart';
import 'welcome_screen.dart';

/// Sign in with a real external wallet (MetaMask, Trust Wallet, Rainbow,
/// ...) instead of the on-device Mera key — structurally [showMeraSheet]'s
/// twin, connecting a [WalletConnectSigner] to the exact same
/// [MeraController]/gateway flow rather than a separate one. Requires
/// [AppConfig.walletConnectProjectId] (a free id from cloud.reown.com) —
/// with none configured this shows why instead of trying to connect and
/// failing unexplained.
///
/// Built on raw `reown_sign` rather than `reown_appkit`'s bundled modal — see
/// wallet_connect_signer.dart for why — so this sheet is its own connect UI:
/// generate a pairing URI, hand it to the OS (which offers every installed
/// WalletConnect-capable wallet, same as tapping a `wc:` link anywhere else),
/// and wait for that wallet to accept.
Future<void> showWalletConnectSheet(BuildContext context, AppConfig config) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (_) => _WalletConnectSheet(config: config),
  );
}

class _WalletConnectSheet extends StatefulWidget {
  const _WalletConnectSheet({required this.config});
  final AppConfig config;

  @override
  State<_WalletConnectSheet> createState() => _WalletConnectSheetState();
}

class _WalletConnectSheetState extends State<_WalletConnectSheet>
    with WidgetsBindingObserver {
  late final MeraController _controller = MeraController(
    config: widget.config,
  );
  late final String _chainId = 'eip155:${widget.config.chainId}';

  ReownSignClient? _client;
  Uri? _pairingUri;
  bool _navigated = false;
  bool _initializing = true;
  bool _connecting = false;
  String? _initError;
  String? _connectError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller.addListener(_onControllerChanged);
    if (widget.config.walletConnectProjectId.isNotEmpty) {
      _init();
    } else {
      _initializing = false;
    }
  }

  // Android (and, less aggressively, iOS) suspends the relay websocket while
  // this app is backgrounded to let the wallet app take the foreground for
  // approval — reown_appkit's modal does exactly this same reconnect on
  // resume internally; dropping to reown_sign directly means we own it.
  // Without it, the wallet's approval message arrives at the relay before
  // we're listening again and `connect()`'s session future never resolves,
  // which looks identical to a hang forever.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final relay = _client?.core.relayClient;
    if (relay != null && !relay.isConnected) {
      relay.connect();
    }
  }

  Future<void> _init() async {
    try {
      final client = await ReownSignClient.createInstance(
        projectId: widget.config.walletConnectProjectId,
        metadata: const PairingMetadata(
          name: 'Sokoni',
          description:
              'Trade on Monad with your fingerprint. Balances in AUSD.',
          url: 'https://sokoni.app',
          icons: [],
          // Where a wallet sends the person back to once they've approved.
          // This rides along in the session proposal, so it covers the whole
          // session — the first connection and every later signature — not
          // just this pairing. The scheme is registered in
          // android/app/src/main/AndroidManifest.xml and ios/Runner/Info.plist;
          // honouring it is the wallet's choice, so the flow still has to
          // work when nothing comes back (see wallet_connect_signer.dart).
          redirect: Redirect(native: 'sokoni://'),
        ),
      );
      if (!mounted) return;
      setState(() {
        _client = client;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = e.toString();
        _initializing = false;
      });
    }
  }

  Future<void> _connect() async {
    final client = _client;
    if (client == null || _connecting) return;
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      final response = await client.connect(
        optionalNamespaces: {
          'eip155': RequiredNamespace(
            chains: [_chainId],
            // personal_sign is all WalletConnectSigner needs — see
            // wallet_connect_signer.dart.
            methods: const ['personal_sign'],
            events: const ['chainChanged', 'accountsChanged'],
          ),
        },
      );
      final uri = response.uri;
      if (uri != null) {
        setState(() => _pairingUri = uri);
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      final session = await response.session.future;
      if (!mounted) return;
      _navigated = true;
      await _controller.useWallet(
        WalletConnectSigner(client, session, chainId: _chainId),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _connectError = e.toString());
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
    final account = _controller.state.account;
    if (account != null && mounted && _navigated) {
      _enterApp(account);
    }
  }

  void _enterApp(MeraAccountInfo meraAccount) {
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.pushReplacement(
      MaterialPageRoute(
        builder:
            (_) => AppShell(
              config: widget.config,
              // Same conversion showMeraSheet uses — nothing downstream
              // reads credentialId for a Mera-owned account.
              account: AccountInfo(
                credentialId: meraAccount.owner,
                address: meraAccount.address,
                deployed: meraAccount.deployed,
              ),
              onLogout:
                  () => navigator.pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (_) => WelcomeScreen(config: widget.config),
                    ),
                    (route) => false,
                  ),
            ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Connect a wallet',
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Sign with MetaMask, Trust Wallet, or any other WalletConnect '
            'wallet — your key never leaves that app.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 20),
          if (widget.config.walletConnectProjectId.isEmpty)
            const _Notice(
              message: 'Wallet connect is not configured on this build yet.',
            )
          else if (_initializing)
            const Center(child: CircularProgressIndicator())
          else if (_initError != null)
            _Notice(message: 'Could not start wallet connect: $_initError')
          else if (_controller.state.error != null)
            _Notice(message: _controller.state.error!)
          else if (_connectError != null)
            _Notice(message: 'Could not connect: $_connectError')
          else if (_controller.state.isBusy || _connecting)
            Column(
              children: [
                const Center(child: CircularProgressIndicator()),
                if (_pairingUri != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Waiting for your wallet app to approve the connection...',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: _pairingUri.toString()),
                      );
                    },
                    child: const Text('Copy connect link'),
                  ),
                ],
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: _connect,
                icon: const Icon(Icons.account_balance_wallet_outlined),
                label: const Text('Connect wallet'),
              ),
            ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
