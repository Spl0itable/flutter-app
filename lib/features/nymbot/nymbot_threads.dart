/// Nymbot inside CHANNEL message threads — the thread half of the `?`/@Nymbot
/// interception (`_threadBotQuoteContext` / `_threadBotConversation`,
/// threads.js).
///
/// A thread IS the conversation: a plain reply under one of Nymbot's messages
/// continues it the same way a quote-reply does, the whole thread is the
/// context the worker gets, and the reply is tagged back into the thread
/// (`threadRoot` → `['e', root, '', 'root']`, bot.js). Without this a game
/// answered inside a thread loses its state — the bot never hears the guess,
/// and its answer lands in the flat channel.
///
/// Pure functions over [AppState] so they unit-test without a controller.
library;

import '../../core/utils/nym_utils.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';

/// The `[gc:BASE64]` token Nymbot carries while a wordplay game is unfinished.
final RegExp _gameTokenRe = RegExp(r'\[gc:[A-Za-z0-9+/=]+\]');

/// Per-entry cap on the transcript text sent to the worker.
const int _maxEntryChars = 1000;

/// Default number of transcript entries sent (`MAX_CONVERSATION_HISTORY` is 20
/// worker-side; sending more just gets trimmed).
const int _maxEntries = 20;

/// True when [m] was posted by the verified Nymbot key.
bool _isBotMessage(Message m, String botPubkey) =>
    m.pubkey == botPubkey || m.pubkey.toLowerCase() == botPubkey.toLowerCase();

/// The thread's messages for [rootId] in [storageKey]: root first, then its
/// replies, chronological.
List<Message> threadChainFor(AppState s, String storageKey, String rootId) {
  if (!appThreadsEnabled || rootId.isEmpty) return const <Message>[];
  final root = threadRootMessage(s, storageKey, rootId);
  if (root == null) return const <Message>[];
  return <Message>[root, ...threadRepliesFor(s, storageKey, rootId)];
}

/// The Nymbot message a plain thread reply is answering, or null when the
/// thread should not auto-route to the bot.
///
/// Nymbot has to be the thread's ROOT or its LAST speaker — a thread nobody
/// asked it into still needs an explicit `?command` or `@Nymbot` mention, so
/// two people talking under a message the bot once touched don't ping it on
/// every line. Resolve this BEFORE publishing the outgoing message, while the
/// bot is still the thread's last speaker.
///
/// When a game is in flight the newest `[gc:]`-carrying bot message wins:
/// quoting one without the token would route the guess to `?ask` and drop the
/// game.
Message? threadBotReplyTarget(
  AppState s,
  String storageKey,
  String rootId, {
  String botPubkey = kNymbotPubkey,
}) {
  final chain = threadChainFor(s, storageKey, rootId)
      .where((m) => m.content.trim().isNotEmpty)
      .toList();
  if (chain.isEmpty) return null;
  if (!_isBotMessage(chain.first, botPubkey) &&
      !_isBotMessage(chain.last, botPubkey)) {
    return null;
  }
  final bots = chain.where((m) => _isBotMessage(m, botPubkey)).toList();
  if (bots.isEmpty) return null;
  for (var i = bots.length - 1; i >= 0; i--) {
    if (_gameTokenRe.hasMatch(bots[i].content)) return bots[i];
  }
  return bots.last;
}

/// `nym#abcd` — the shape quote-replies use, so the worker can tell the bot's
/// own turns apart from the humans' in a transcript.
String threadEntryAuthor(Message m) {
  final base = stripPubkeySuffix(m.author).trim();
  final nym = base.isEmpty ? 'nym' : base;
  return m.pubkey.isEmpty ? nym : '$nym#${getPubkeySuffix(m.pubkey)}';
}

/// The thread transcript as `/api/bot` `conversation` entries, in the same
/// `{author, text}` shape the quote chain produces.
///
/// [exclude] drops the message just published (it travels separately as the
/// question), compared against the same truncation the entries carry.
List<Map<String, String>> threadBotConversation(
  AppState s,
  String storageKey,
  String rootId, {
  String? exclude,
  int limit = _maxEntries,
}) {
  final entries = <Map<String, String>>[];
  for (final m in threadChainFor(s, storageKey, rootId)) {
    final text = m.content.trim().isEmpty
        ? ''
        : (m.content.length > _maxEntryChars
            ? m.content.substring(0, _maxEntryChars)
            : m.content);
    if (text.trim().isEmpty) continue;
    entries.add({'author': threadEntryAuthor(m), 'text': text});
  }
  if (exclude != null && exclude.trim().isNotEmpty && entries.isNotEmpty) {
    final tail = exclude.length > _maxEntryChars
        ? exclude.substring(0, _maxEntryChars)
        : exclude;
    if (entries.last['text']!.trim() == tail.trim()) entries.removeLast();
  }
  if (entries.length > limit) {
    return entries.sublist(entries.length - limit);
  }
  return entries;
}
