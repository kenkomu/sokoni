import 'package:flutter/material.dart';

import '../../core/config.dart';
import '../../data/api/sokoni_api.dart';
import '../onboarding/passkey_controller.dart' show describeFailure;

/// Behind Profile's "Help and Support" tile — a chat grounded server-side in
/// this account's own balances and recent activity (see
/// backend/internal/assistant's doc), not a generic FAQ bot. Kept as a
/// simple in-widget message list rather than its own controller: one
/// request per message, no streaming, no history sent back to the gateway
/// (each question is answered independently — see SokoniApi.assist's doc).
Future<void> showAssistantSheet(
  BuildContext context, {
  required AppConfig config,
  required AccountInfo account,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _AssistantSheet(config: config, address: account.address),
  );
}

class _Message {
  const _Message({
    required this.text,
    required this.fromUser,
    this.isError = false,
  });
  final String text;
  final bool fromUser;
  final bool isError;
}

class _AssistantSheet extends StatefulWidget {
  const _AssistantSheet({required this.config, required this.address});
  final AppConfig config;
  final String address;

  @override
  State<_AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<_AssistantSheet> {
  late final SokoniApi _api = SokoniApi(baseUrl: widget.config.apiBaseUrl);
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _messages = <_Message>[];
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final question = _controller.text.trim();
    if (question.isEmpty || _sending) return;
    setState(() {
      _messages.add(_Message(text: question, fromUser: true));
      _sending = true;
    });
    _controller.clear();
    _scrollToEnd();
    try {
      final answer = await _api.assist(widget.address, question);
      if (!mounted) return;
      setState(() => _messages.add(_Message(text: answer, fromUser: false)));
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _messages.add(
          _Message(text: describeFailure(e), fromUser: false, isError: true),
        ),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
      _scrollToEnd();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.85,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Row(
                children: [
                  Icon(Icons.support_agent, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(
                    'Help and Support',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child:
                  _messages.isEmpty
                      ? _EmptyState(onTapSuggestion: _ask)
                      : ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        itemCount: _messages.length,
                        itemBuilder:
                            (context, i) => _Bubble(message: _messages[i]),
                      ),
            ),
            if (_sending)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Ask a question…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(24)),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _ask(String question) {
    _controller.text = question;
    _send();
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onTapSuggestion});
  final ValueChanged<String> onTapSuggestion;

  static const _suggestions = [
    'What is a passkey and why don\'t I need a seed phrase?',
    'Why did my last trade fail or expire?',
    'What tokens do I currently hold?',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Ask anything about your account, a trade, or how Sokoni works. '
            'Answers use your real balances and recent activity.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          for (final s in _suggestions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton(
                onPressed: () => onTapSuggestion(s),
                style: OutlinedButton.styleFrom(
                  alignment: Alignment.centerLeft,
                ),
                child: Text(s),
              ),
            ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});
  final _Message message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg =
        message.isError
            ? theme.colorScheme.errorContainer
            : message.fromUser
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerLow;
    final fg =
        message.isError
            ? theme.colorScheme.onErrorContainer
            : message.fromUser
            ? theme.colorScheme.onPrimary
            : theme.colorScheme.onSurface;
    return Align(
      alignment:
          message.fromUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          style: theme.textTheme.bodyMedium?.copyWith(color: fg),
        ),
      ),
    );
  }
}
