import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/event_kinds.dart';
import '../core/utils/nym_utils.dart';
import '../features/channels/channel_manager.dart';
import '../features/emoji/custom_emoji.dart'
    show
        CustomEmojiPack,
        CustomEmojiState,
        emojiPrefsProvider,
        kCustomEmojiMapKey,
        kCustomEmojiPacksKey,
        loadCustomEmojiState;
import '../features/emoji/emoji_data.dart';
import '../features/groups/group_logic.dart';
import '../features/pms/pm_logic.dart';
import '../features/polls/poll_logic.dart';
import '../features/zaps/zap_logic.dart';
import '../models/channel.dart';
import '../models/group.dart';
import '../models/message.dart';
import '../models/nostr_event.dart';
import '../models/pm_conversation.dart';
import '../models/poll.dart';
import '../models/user.dart';
import '../services/nostr/event_mapper.dart';
import 'settings_provider.dart';

/// Identifies what the chat pane is currently showing. Mirrors the PWA's
/// mutually-exclusive `currentChannel` / `currentPM` / `currentGroup` +
/// `inPMMode` state (docs/specs/03 §3.5).
enum ViewKind { channel, pm, group }

/// The active conversation selector. [storageKey] matches the keying used by
/// the in-memory [AppState.messages] map (channel = `#<key>`, PM = `pm-<pubkey>`,
/// group = `group-<id>`).
class ChatView {
  const ChatView.channel(this.id)
      : kind = ViewKind.channel,
        storageKey = '#$id';
  const ChatView.pm(this.id)
      : kind = ViewKind.pm,
        storageKey = 'pm-$id';
  const ChatView.group(this.id)
      : kind = ViewKind.group,
        storageKey = 'group-$id';

  final ViewKind kind;

  /// Channel key (geohash or name), PM peer pubkey, or group id.
  final String id;

  /// Key into [AppState.messages].
  final String storageKey;

  bool get inPMMode => kind != ViewKind.channel;

  @override
  bool operator ==(Object other) =>
      other is ChatView && other.kind == kind && other.id == id;

  @override
  int get hashCode => Object.hash(kind, id);
}

/// A single emoji reaction tally on a message (UI-only aggregate).
class MessageReaction {
  const MessageReaction({
    required this.emoji,
    required this.count,
    this.userReacted = false,
  });
  final String emoji;
  final int count;
  final bool userReacted;
}

/// Per-message zap aggregate (zaps.js `this.zaps` entry, UI-facing form):
/// total sats + the set of zappers. [receipts] holds the dedup keys (lowercased
/// `b:<bolt11>` or receipt id) so the verify-URL confirmation and a later
/// NIP-57 receipt for the same payment don't double-count.
class MessageZaps {
  MessageZaps({int? totalSats, Set<String>? zappers, Set<String>? receipts})
      : totalSats = totalSats ?? 0,
        zappers = zappers ?? <String>{},
        receipts = receipts ?? <String>{};

  int totalSats;
  final Set<String> zappers;
  final Set<String> receipts;

  int get zapperCount => zappers.length;
}

/// In-memory UI state for the shell. This is intentionally a self-contained
/// placeholder store seeded with SAMPLE data so the shell renders like the PWA
/// before any networking exists.
///
/// !!! PLACEHOLDER SEED DATA !!!
/// Everything below (channels, users, PMs, groups, messages, reactions) is
/// hard-coded demo content. The real Nostr / relay layer (channels.js,
/// messages.js, pms.js, groups.js — see docs/specs/03) will replace this store
/// wholesale; the providers exposed here are the seam to plug it into.
class AppState {
  AppState({
    required this.selfPubkey,
    required this.selfNym,
    required this.channels,
    required this.pmConversations,
    required this.groups,
    required this.users,
    required this.messages,
    required this.reactions,
    required this.unreadCounts,
    required this.view,
    this.connectedRelays = 0,
    Map<String, int>? typing,
    Map<String, Poll>? polls,
    Map<String, MessageZaps>? zaps,
    Set<String>? pinnedChannels,
    Set<String>? hiddenChannels,
    Set<String>? blockedChannels,
    Map<String, int>? channelLastActivity,
    Set<String>? friends,
    Set<String>? blockedUsers,
    Set<String>? blockedKeywords,
  })  : typing = typing ?? <String, int>{},
        polls = polls ?? <String, Poll>{},
        zaps = zaps ?? <String, MessageZaps>{},
        pinnedChannels = pinnedChannels ?? <String>{},
        hiddenChannels = hiddenChannels ?? <String>{},
        blockedChannels = blockedChannels ?? <String>{},
        channelLastActivity = channelLastActivity ?? <String, int>{},
        friends = friends ?? <String>{},
        blockedUsers = blockedUsers ?? <String>{},
        blockedKeywords = blockedKeywords ?? <String>{};

  /// The current user's identity.
  final String selfPubkey;
  final String selfNym;

  /// Number of relays currently connected (0 = offline).
  final int connectedRelays;

  final List<ChannelEntry> channels;
  final List<PMConversation> pmConversations;
  final List<Group> groups;

  /// pubkey → User.
  final Map<String, User> users;

  /// view storageKey → ordered messages (oldest first).
  final Map<String, List<Message>> messages;

  /// message id → reaction tallies.
  final Map<String, List<MessageReaction>> reactions;

  /// channel/pm/group key → unread count (sidebar pill).
  final Map<String, int> unreadCounts;

  /// `<storageKey>|<pubkey>` → typing-stop expiry (ms since epoch). A peer is
  /// "typing" in a view while now < expiry. Cleared on stop / timeout.
  final Map<String, int> typing;

  /// pollId → Poll (kind 30078 `nym-poll`); channel-only (docs/specs/03 §6).
  final Map<String, Poll> polls;

  /// message id → per-message zap aggregate (kind 9735 receipts).
  final Map<String, MessageZaps> zaps;

  /// Favorited channel keys (`nym_pinned_channels`).
  final Set<String> pinnedChannels;

  /// Hidden-from-sidebar channel keys (`nym_hidden_channels`).
  final Set<String> hiddenChannels;

  /// Blocked-from-discovery channel keys (`nym_blocked_channels`).
  final Set<String> blockedChannels;

  /// channel storage key (`#<key>`) → last-activity ms (`nym_channel_activity`).
  final Map<String, int> channelLastActivity;

  /// Friended pubkeys (`nym_friends`). users.js `this.friends` (isFriend).
  final Set<String> friends;

  /// Blocked-user pubkeys (`nym_blocked`). users.js `this.blockedUsers`
  /// (toggleBlockUserByPubkey / hideMessagesFromBlockedUser).
  final Set<String> blockedUsers;

  /// Blocked keywords, all lowercased (`nym_blocked_keywords`). users.js
  /// `this.blockedKeywords` (hasBlockedKeyword — matches content OR author nym).
  final Set<String> blockedKeywords;

  final ChatView view;

  /// True when [pubkey] is a friend (users.js `isFriend`).
  bool isFriend(String pubkey) => friends.contains(pubkey);

  /// True when [pubkey] is blocked (users.js `blockedUsers.has`).
  bool isUserBlocked(String pubkey) => blockedUsers.contains(pubkey);

  /// True when [text] OR [nickname] contains any blocked keyword,
  /// case-insensitive. Mirrors messages.js `hasBlockedKeyword(text, nickname)`:
  /// the nickname is reduced to its base nym (suffix/flair stripped) first.
  bool hasBlockedKeyword(String text, [String? nickname]) {
    if (blockedKeywords.isEmpty) return false;
    final lowerText = text.toLowerCase();
    final lowerNick =
        (nickname != null && nickname.isNotEmpty)
            ? stripPubkeySuffix(nickname).toLowerCase()
            : '';
    for (final keyword in blockedKeywords) {
      if (lowerText.contains(keyword) ||
          (lowerNick.isNotEmpty && lowerNick.contains(keyword))) {
        return true;
      }
    }
    return false;
  }

  /// True when [m] should be hidden from message lists: blocked author, or a
  /// keyword match on its content / author (own messages are never filtered by
  /// keyword — messages.js `if (!msg.isOwn && this.hasBlockedKeyword(...))`).
  bool isMessageFiltered(Message m) {
    if (blockedUsers.contains(m.pubkey)) return true;
    if (!m.isOwn && hasBlockedKeyword(m.content, m.author)) return true;
    return false;
  }

  AppState copyWith({
    String? selfPubkey,
    String? selfNym,
    ChatView? view,
    int? connectedRelays,
  }) =>
      AppState(
        selfPubkey: selfPubkey ?? this.selfPubkey,
        selfNym: selfNym ?? this.selfNym,
        channels: channels,
        pmConversations: pmConversations,
        groups: groups,
        users: users,
        messages: messages,
        reactions: reactions,
        unreadCounts: unreadCounts,
        view: view ?? this.view,
        connectedRelays: connectedRelays ?? this.connectedRelays,
        typing: typing,
        polls: polls,
        zaps: zaps,
        pinnedChannels: pinnedChannels,
        hiddenChannels: hiddenChannels,
        blockedChannels: blockedChannels,
        channelLastActivity: channelLastActivity,
        friends: friends,
        blockedUsers: blockedUsers,
        blockedKeywords: blockedKeywords,
      );

  /// Builds the seeded demo store (used until a live identity boots).
  factory AppState.seed() => _seedAppState();

  /// An empty live store for a freshly-booted identity (only #nymchat).
  factory AppState.live(String pubkey, String nym) => AppState(
        selfPubkey: pubkey,
        selfNym: nym,
        channels: [ChannelEntry(channel: kDefaultChannel)],
        pmConversations: [],
        groups: [],
        users: {},
        messages: {},
        reactions: {},
        unreadCounts: {},
        view: const ChatView.channel(kDefaultChannel),
      );
}

// ---------------------------------------------------------------------------
// SAMPLE / SEED DATA  — replace with relay-backed data later.
// ---------------------------------------------------------------------------

// Sample pubkeys (64-hex). The last 4 hex chars form the display suffix
// (docs/specs/03 §2.3: `getPubkeySuffix(pubkey) = pubkey.slice(-4)`).
const String _selfPubkey =
    '0000000000000000000000000000000000000000000000000000000000001a2b';
const String _pkSatoshi =
    '11111111111111111111111111111111111111111111111111111111deadbeef';
const String _pkNeo =
    '2222222222222222222222222222222222222222222222222222222222223c4d';
const String _pkTrinity =
    '33333333333333333333333333333333333333333333333333333333000099ff';
const String _pkOracle =
    '4444444444444444444444444444444444444444444444444444444444445e6f';
const String _pkBot =
    '5555555555555555555555555555555555555555555555555555555555550b07';

const String _selfNym = 'you#1a2b';

AppState _seedAppState() {
  final now = DateTime.now();
  int secAgo(int s) => now.subtract(Duration(seconds: s)).millisecondsSinceEpoch ~/ 1000;

  // --- channels (named + geohash) ---
  final channels = <ChannelEntry>[
    ChannelEntry(channel: 'nymchat'),
    ChannelEntry(channel: 'bitcoin'),
    ChannelEntry(channel: 'dev'),
    // Geohash channel near San Francisco (#9q8y).
    ChannelEntry(channel: '9q8y', geohash: '9q8y'),
  ];

  // --- users + presence ---
  final users = <String, User>{
    _selfPubkey: User(
      pubkey: _selfPubkey,
      nym: _selfNym,
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkSatoshi: User(
      pubkey: _pkSatoshi,
      nym: 'satoshi#beef',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkNeo: User(
      pubkey: _pkNeo,
      nym: 'neo#3c4d',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
    _pkTrinity: User(
      pubkey: _pkTrinity,
      nym: 'trinity#99ff',
      status: UserStatus.away,
      lastSeen: now.subtract(const Duration(minutes: 12)).millisecondsSinceEpoch,
      awayMessage: 'afk',
    ),
    _pkOracle: User(
      pubkey: _pkOracle,
      nym: 'oracle#5e6f',
      status: UserStatus.offline,
      lastSeen: now.subtract(const Duration(hours: 3)).millisecondsSinceEpoch,
    ),
    _pkBot: User(
      pubkey: _pkBot,
      nym: 'nymbot#0b07',
      status: UserStatus.online,
      lastSeen: now.millisecondsSinceEpoch,
    ),
  };

  // --- PM conversations ---
  final pms = <PMConversation>[
    PMConversation(
      pubkey: _pkSatoshi,
      nym: 'satoshi#beef',
      lastMessageTime:
          now.subtract(const Duration(minutes: 4)).millisecondsSinceEpoch,
    ),
    PMConversation(
      pubkey: _pkNeo,
      nym: 'neo#3c4d',
      lastMessageTime:
          now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch,
    ),
  ];

  // --- groups ---
  final groups = <Group>[
    Group(
      id: 'aaaa0000000000000000000000000000000000000000000000000000group01',
      name: 'flutter-rewrite',
      members: [_selfPubkey, _pkNeo, _pkTrinity],
      createdBy: _selfPubkey,
      lastMessageTime:
          now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch,
    ),
  ];

  int seq = 0;
  Message msg({
    required String id,
    required String pubkey,
    required String author,
    required String content,
    required int createdAt,
    bool isOwn = false,
    bool isPM = false,
    bool isGroup = false,
    bool isBot = false,
    String? channel,
    String? geohash,
    String? conversationKey,
    String? conversationPubkey,
    DeliveryStatus deliveryStatus = DeliveryStatus.sent,
    bool isEdited = false,
  }) {
    return Message(
      id: id,
      pubkey: pubkey,
      author: author,
      content: content,
      createdAt: createdAt,
      seq: seq++,
      isOwn: isOwn,
      isPM: isPM,
      isGroup: isGroup,
      isBot: isBot,
      channel: channel,
      geohash: geohash,
      conversationKey: conversationKey,
      conversationPubkey: conversationPubkey,
      deliveryStatus: deliveryStatus,
      isEdited: isEdited,
      senderVerified: true,
    );
  }

  // --- #nymchat messages (IRC-worthy variety) ---
  final nymchatMsgs = <Message>[
    msg(
      id: 'm01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'nymchat',
      content: 'gm everyone — the native Flutter shell is looking sharp today',
      createdAt: secAgo(60 * 18),
    ),
    msg(
      id: 'm02',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'nymchat',
      content: 'wake up… the messenger has you 🐇',
      createdAt: secAgo(60 * 16),
    ),
    msg(
      id: 'm03',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'pixel-matching the IRC layout to the PWA right now',
      createdAt: secAgo(60 * 15),
      isOwn: true,
    ),
    msg(
      id: 'm04',
      pubkey: _pkTrinity,
      author: 'trinity#99ff',
      channel: 'nymchat',
      // reply / quote line (formatter renders leading `>` as a quote).
      content:
          '> pixel-matching the IRC layout to the PWA right now\nboth bubble and IRC modes? nice.',
      createdAt: secAgo(60 * 14),
    ),
    msg(
      id: 'm05',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'nymchat',
      // code block sample.
      content:
          'here is the wire shape:\n```dart\nfinal wire = channelWire(key);\nevent.kind = wire.kind; // 20000 | 23333\n```',
      createdAt: secAgo(60 * 12),
    ),
    msg(
      id: 'm06',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'nymchat',
      content: '🔥🔥🔥',
      createdAt: secAgo(60 * 11),
    ),
    msg(
      id: 'm07',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'shipping the shell, relay layer plugs in next',
      createdAt: secAgo(60 * 3),
      isOwn: true,
    ),
    // consecutive same-author within 5 min (tests bubble grouping).
    msg(
      id: 'm08',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'nymchat',
      content: 'then PMs and groups over NIP-17',
      createdAt: secAgo(60 * 3 - 20),
      isOwn: true,
    ),
  ];

  // --- geohash channel #9q8y messages ---
  final geoMsgs = <Message>[
    msg(
      id: 'g01',
      pubkey: _pkOracle,
      author: 'oracle#5e6f',
      geohash: '9q8y',
      content: 'anyone around the bay? 37.77°N, 122.41°W',
      createdAt: secAgo(60 * 40),
    ),
    msg(
      id: 'g02',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      geohash: '9q8y',
      content: 'right here. geohash channels are wild',
      createdAt: secAgo(60 * 22),
    ),
    msg(
      id: 'g03',
      pubkey: _selfPubkey,
      author: _selfNym,
      geohash: '9q8y',
      content: 'local-first social. love it 🌉',
      createdAt: secAgo(60 * 5),
      isOwn: true,
    ),
  ];

  // --- #bitcoin / #dev light seeds ---
  final bitcoinMsgs = <Message>[
    msg(
      id: 'b01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      channel: 'bitcoin',
      content: 'running bitcoin',
      createdAt: secAgo(60 * 90),
    ),
    msg(
      id: 'b02',
      pubkey: _pkBot,
      author: 'nymbot#0b07',
      channel: 'bitcoin',
      content: 'block height looks healthy ⚡',
      createdAt: secAgo(60 * 50),
      isBot: true,
    ),
  ];

  final devMsgs = <Message>[
    msg(
      id: 'd01',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      channel: 'dev',
      content: 'who owns the messages_list widget?',
      createdAt: secAgo(60 * 33),
    ),
    msg(
      id: 'd02',
      pubkey: _selfPubkey,
      author: _selfNym,
      channel: 'dev',
      content: 'me — IRC + bubble in one row builder',
      createdAt: secAgo(60 * 31),
      isOwn: true,
    ),
  ];

  // --- PM thread with satoshi (delivery ticks) ---
  final pmKeySat = 'pm-$_pkSatoshi';
  final pmSat = <Message>[
    msg(
      id: 'pm01',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      content: 'hey, can you review the gift-wrap envelope?',
      createdAt: secAgo(60 * 30),
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
    ),
    msg(
      id: 'pm02',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'on it — NIP-17 rumor → seal → wrap, right?',
      createdAt: secAgo(60 * 28),
      isOwn: true,
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
      deliveryStatus: DeliveryStatus.read,
    ),
    msg(
      id: 'pm03',
      pubkey: _pkSatoshi,
      author: 'satoshi#beef',
      content: 'exactly. fresh ephemeral key per wrap.',
      createdAt: secAgo(60 * 5),
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
    ),
    msg(
      id: 'pm04',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'shipping the delivery ticks too ✓✓',
      createdAt: secAgo(60 * 4),
      isOwn: true,
      isPM: true,
      conversationKey: pmKeySat,
      conversationPubkey: _pkSatoshi,
      deliveryStatus: DeliveryStatus.delivered,
    ),
  ];

  final pmKeyNeo = 'pm-$_pkNeo';
  final pmNeo = <Message>[
    msg(
      id: 'pn01',
      pubkey: _pkNeo,
      author: 'neo#3c4d',
      content: 'follow the white rabbit',
      createdAt: secAgo(60 * 60),
      isPM: true,
      conversationKey: pmKeyNeo,
      conversationPubkey: _pkNeo,
    ),
  ];

  // --- group messages ---
  final groupId = groups.first.id;
  final groupKey = 'group-$groupId';
  final groupMsgs = <Message>[
    msg(
      id: 'gr01',
      pubkey: _pkTrinity,
      author: 'trinity#99ff',
      content: 'sidebar sections collapsing cleanly now',
      createdAt: secAgo(60 * 35),
      isGroup: true,
      conversationKey: groupKey,
    ),
    msg(
      id: 'gr02',
      pubkey: _selfPubkey,
      author: _selfNym,
      content: 'nice. composer SEND wired for local echo',
      createdAt: secAgo(60 * 30),
      isOwn: true,
      isGroup: true,
      conversationKey: groupKey,
      deliveryStatus: DeliveryStatus.delivered,
    ),
  ];

  final messages = <String, List<Message>>{
    '#nymchat': nymchatMsgs,
    '#9q8y': geoMsgs,
    '#bitcoin': bitcoinMsgs,
    '#dev': devMsgs,
    pmKeySat: pmSat,
    pmKeyNeo: pmNeo,
    groupKey: groupMsgs,
  };

  // --- sample reactions keyed by message id ---
  final reactions = <String, List<MessageReaction>>{
    'm02': const [MessageReaction(emoji: '🐇', count: 3)],
    'm05': const [
      MessageReaction(emoji: '👍', count: 5, userReacted: true),
      MessageReaction(emoji: '🤯', count: 2),
    ],
    'm06': const [MessageReaction(emoji: '🔥', count: 7, userReacted: true)],
    'g02': const [MessageReaction(emoji: '🌍', count: 2)],
  };

  final unread = <String, int>{
    'bitcoin': 3,
    'dev': 1,
    _pkNeo: 2, // PM unread
  };

  return AppState(
    selfPubkey: _selfPubkey,
    selfNym: _selfNym,
    channels: channels,
    pmConversations: pms,
    groups: groups,
    users: users,
    messages: messages,
    reactions: reactions,
    unreadCounts: unread,
    view: const ChatView.channel('nymchat'),
  );
}

// ---------------------------------------------------------------------------
// Riverpod store
// ---------------------------------------------------------------------------

/// Holds the in-memory [AppState]. Supports switching views and a local-echo
/// send (append a self [Message] to the current view).
class AppStateNotifier extends StateNotifier<AppState> {
  AppStateNotifier() : super(AppState.seed());

  /// Fired whenever a conversation is opened via [switchView] (channel, PM, or
  /// group). The controller wires this to its D1 history backfill so opening a
  /// channel/group fetches the archive (mirrors the PWA's per-open
  /// `channelRestoreFromD1` in `switchChannel`). Best-effort and may be null
  /// (e.g. before the controller boots, or in pure UI/state tests).
  void Function(ChatView view)? onViewOpened;

  int _localSeq = 1000000;
  int _ingestSeq = 1;
  final Set<String> _seenIds = <String>{};

  /// nymMessageIds already ingested (PM/group dedup, since wrap ids differ per
  /// recipient copy but share the `['x', …]` id).
  final Set<String> _seenNymMessageIds = <String>{};

  /// PM peer pubkeys the user explicitly closed; older backlog for them is
  /// ignored (docs/specs/03 §3.3 `closedPMs`).
  final Set<String> _closedPMs = <String>{};

  /// peer pubkey → close timestamp (sec). A closed conversation re-opens only
  /// when a message strictly newer than this arrives (pms.js `closedPMTimes`),
  /// so stale relay backlog can't resurrect a thread the user just deleted.
  final Map<String, int> _closedPMTimes = <String, int>{};

  /// Group ids the user left; their messages/controls are ignored.
  final Set<String> _leftGroups = <String>{};

  int _nextLocalSeq() => _localSeq++;
  int _nextIngestSeq() => _ingestSeq++;

  Set<String> get closedPMs => _closedPMs;

  /// Switches this store to a live, identity-backed empty state. Called by the
  /// NostrController once an identity boots.
  void goLive(String pubkey, String nym) {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    state = AppState.live(pubkey, nym);
  }

  /// Resets the store to its pre-login state on sign-out (app.js `signOut` →
  /// reload). Clears every session-scoped dedup/private map (so a new identity
  /// can't inherit the old one's seen ids / closed PMs / reactor state) and
  /// returns the visible store to the seed. Mirrors [goLive] but without a live
  /// identity; the boot gate then shows the setup modal.
  void reset() {
    _seenIds.clear();
    _seenNymMessageIds.clear();
    _closedPMs.clear();
    _closedPMTimes.clear();
    _leftGroups.clear();
    _reactors.clear();
    _reactionLastAction.clear();
    _processedPollVoteIds.clear();
    _pendingPollVotes.clear();
    state = AppState.seed();
  }

  void setIdentity(String pubkey, String nym) {
    state = state.copyWith(selfPubkey: pubkey, selfNym: nym);
  }

  void setConnectedRelays(int count) {
    if (count == state.connectedRelays) return;
    state = state.copyWith(connectedRelays: count);
  }

  /// Per-message reactor map: messageId → emoji → reactor pubkey → nym.
  /// Mirrors the PWA's `reactions: Map<msgId, Map<emoji, Map<pubkey,nym>>>`
  /// (docs/specs/03 §5.3). The UI-facing [AppState.reactions] tallies are
  /// derived from this on each mutation.
  final Map<String, Map<String, Map<String, String>>> _reactors = {};

  /// `messageId:emoji:pubkey` → last action ts (sec). Latest action wins on
  /// out-of-order relay delivery (`reactionLastAction`, reactions.js).
  final Map<String, int> _reactionLastAction = {};

  /// Dedup set for poll-vote events (`processedPollVoteIds`, cap 3000).
  final Set<String> _processedPollVoteIds = {};

  /// Votes that arrived before their poll (`pendingPollVotes`).
  final Map<String, List<PollVote>> _pendingPollVotes = {};

  Set<String> get processedPollVoteIds => _processedPollVoteIds;

  /// Routes a verified inbound Nostr event into the store (channel messages,
  /// profiles, reactions, polls, zaps). Deduplicates by event id.
  void ingestEvent(NostrEvent e) {
    switch (e.kind) {
      case EventKind.geoChannel:
      case EventKind.namedChannel:
        _ingestChannelMessage(e);
      case EventKind.profile:
        _ingestProfile(e);
      case EventKind.reaction:
        _ingestReaction(e);
      case EventKind.zapReceipt:
        ingestZapReceipt(e);
      case EventKind.appData:
        if (PollLogic.isPollEvent(e)) {
          ingestPoll(e);
        } else if (PollLogic.isPollVoteEvent(e)) {
          ingestPollVote(e);
        }
    }
  }

  void _ingestChannelMessage(NostrEvent e) {
    if (e.id.isNotEmpty && !_seenIds.add(e.id)) return;
    final m = EventMapper.channelMessage(e, selfPubkey: state.selfPubkey);
    if (m == null) return;
    final key = EventMapper.channelKeyOf(e);
    if (key == null) return;
    m.seq = _ingestSeq++;

    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    list.add(m);
    list.sort(compareMessages);

    // Track the author as a seen user.
    final u = state.users.putIfAbsent(
      e.pubkey,
      () => User(pubkey: e.pubkey, nym: m.author),
    );
    u.nym = m.author;
    u.lastSeen = m.timestamp;
    if (m.channel != null) u.channels.add(m.channel!);

    // Track last activity for the channel sort (`channelLastActivity`).
    state.channelLastActivity[key] = m.timestamp;

    // Surface the channel in the sidebar on first activity. The PWA lists
    // discovered/active channels (channels.js `addChannelToList`), so any channel
    // we actually receive a message for — live from relays OR from the D1 archive
    // backfill — must appear, unless the user blocked or hid it. Mirrors
    // `addChannel`'s entry/key shape (registry key is the bare lowercase value).
    final isGeo = (m.geohash ?? '').isNotEmpty;
    final regKey = (isGeo ? m.geohash! : (m.channel ?? '')).toLowerCase();
    if (regKey.isNotEmpty &&
        !state.blockedChannels.contains(regKey) &&
        !state.hiddenChannels.contains(regKey) &&
        !state.channels.any((c) => c.key == regKey)) {
      state.channels.add(ChannelEntry(
        channel: m.channel ?? (isGeo ? m.geohash! : regKey),
        geohash: isGeo ? m.geohash! : '',
      ));
    }

    // Bump unread when the message isn't for the active view, isn't ours, and
    // isn't from a blocked user / keyword-filtered (the PWA's unread recompute
    // skips `blockedUsers` — channels.js `_recomputeUnreadCount`).
    if (key != state.view.storageKey && !m.isOwn && !state.isMessageFiltered(m)) {
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    }
    state = state.copyWith();
  }

  void _ingestProfile(NostrEvent e) {
    final p = EventMapper.profile(e);
    if (p == null) return;
    final existing = state.users[e.pubkey];
    if (existing != null) {
      if (existing.profile == null || p.kind0Ts >= existing.profile!.kind0Ts) {
        existing.profile = p;
        if ((p.name ?? '').isNotEmpty) {
          existing.nym = getNymFromPubkey(p.name!, e.pubkey);
        }
      }
    } else {
      state.users[e.pubkey] = User(
        pubkey: e.pubkey,
        nym: getNymFromPubkey(p.name ?? 'anon', e.pubkey),
        profile: p,
      );
    }
    state = state.copyWith();
  }

  void _ingestReaction(NostrEvent e) {
    // Reactions from blocked users are dropped (reactions.js `handleReaction`:
    // `if (this.blockedUsers.has(event.pubkey)) return;`).
    if (state.blockedUsers.contains(e.pubkey)) return;

    // Only process reactions targeting our supported message kinds. When a `k`
    // tag is present it must be one of 20000 (geohash channel) / 23333 (named
    // channel) / 1059 (NIP-17 gift wrap) / 14 (group rumor); otherwise the
    // reaction belongs to another Nostr app and is ignored. A missing `k` tag
    // is allowed (reactions.js then verifies the target is a known message).
    final kTag = e.tagValue('k');
    if (kTag != null &&
        kTag != '20000' &&
        kTag != '23333' &&
        kTag != '1059' &&
        kTag != '14') {
      return;
    }

    final r = EventMapper.reaction(e);
    if (r == null || r.emoji.isEmpty) return;

    // Latest-by-timestamp wins on out-of-order delivery (reactions.js).
    final actionKey = '${r.messageId}:${r.emoji}:${r.reactor}';
    final last = _reactionLastAction[actionKey];
    if (last != null && last > r.ts) return;
    _reactionLastAction[actionKey] = r.ts;
    if (_reactionLastAction.length > 5000) {
      final entries = _reactionLastAction.entries.toList();
      _reactionLastAction
        ..clear()
        ..addEntries(entries.sublist(entries.length - 4000));
    }

    applyReaction(
      messageId: r.messageId,
      emoji: r.emoji,
      reactor: r.reactor,
      removed: r.removed,
      reactorNym: _nymForPubkey(r.reactor),
    );
  }

  /// Applies a single reaction add/remove to the reactor map and recomputes the
  /// message's UI tally. Used by both inbound (`_ingestReaction`) and optimistic
  /// local toggles. Idempotent per (messageId, emoji, reactor).
  void applyReaction({
    required String messageId,
    required String emoji,
    required String reactor,
    required bool removed,
    String? reactorNym,
  }) {
    final byEmoji = _reactors.putIfAbsent(messageId, () => {});
    if (removed) {
      final reactors = byEmoji[emoji];
      if (reactors != null) {
        reactors.remove(reactor);
        if (reactors.isEmpty) byEmoji.remove(emoji);
        if (byEmoji.isEmpty) _reactors.remove(messageId);
      }
    } else {
      byEmoji.putIfAbsent(emoji, () => {})[reactor] =
          reactorNym ?? _nymForPubkey(reactor);
    }
    _recomputeReactionTally(messageId);
    state = state.copyWith();
  }

  /// Rebuilds [AppState.reactions] for [messageId] from the reactor map, marking
  /// `userReacted` when self is among the reactors.
  void _recomputeReactionTally(String messageId) {
    final byEmoji = _reactors[messageId];
    if (byEmoji == null || byEmoji.isEmpty) {
      state.reactions.remove(messageId);
      return;
    }
    final tally = <MessageReaction>[];
    byEmoji.forEach((emoji, reactors) {
      tally.add(MessageReaction(
        emoji: emoji,
        count: reactors.length,
        userReacted: reactors.containsKey(state.selfPubkey),
      ));
    });
    state.reactions[messageId] = tally;
  }

  String _nymForPubkey(String pubkey) {
    final u = state.users[pubkey];
    if (u != null && u.nym.isNotEmpty) return u.nym;
    return getNymFromPubkey('anon', pubkey);
  }

  // -------------------------------------------------------------------------
  // Polls (kind 30078 nym-poll / nym-poll-vote) — channel-only.
  // -------------------------------------------------------------------------

  /// Ingests a poll-create event (dedup by id, honor expiration, require a
  /// question + ≥ 2 options). Replays any buffered votes (polls.js
  /// `handlePollEvent`).
  void ingestPoll(NostrEvent e) {
    if (!PollLogic.isPollEvent(e)) return;
    if (PollLogic.isExpired(e)) return;
    if (state.polls.containsKey(e.id)) return;
    final poll = PollLogic.parsePoll(e);
    if (poll == null) return;
    state.polls[e.id] = poll;

    // Replay buffered votes that arrived before this poll (one per pubkey).
    final buffered = _pendingPollVotes.remove(e.id);
    if (buffered != null) {
      for (final v in buffered) {
        poll.votes.putIfAbsent(v.voter, () => v.optionIndex);
      }
    }
    state = state.copyWith();
  }

  /// Ingests a poll-vote event (dedup `processedPollVoteIds` cap 3000, honor
  /// expiration, buffer when the poll is unknown, one vote/pubkey — first wins).
  /// (polls.js `handlePollVoteEvent`)
  void ingestPollVote(NostrEvent e) {
    if (!PollLogic.isPollVoteEvent(e)) return;
    if (e.id.isNotEmpty && !_processedPollVoteIds.add(e.id)) return;
    if (PollLogic.isExpired(e)) return;
    if (_processedPollVoteIds.length > 3000) {
      final arr = _processedPollVoteIds.toList();
      _processedPollVoteIds
        ..clear()
        ..addAll(arr.sublist(arr.length - 2000));
    }
    final vote = PollLogic.parseVote(e);
    if (vote == null) return;

    final poll = state.polls[vote.pollId];
    if (poll == null) {
      _pendingPollVotes.putIfAbsent(vote.pollId, () => []).add(vote);
      return;
    }
    if (poll.votes.containsKey(vote.voter)) return; // no double-voting
    poll.votes[vote.voter] = vote.optionIndex;
    state = state.copyWith();
  }

  /// Registers a locally-created/voted poll/vote so the UI updates immediately
  /// (publishPoll / votePoll optimistic paths). Returns the [Poll].
  void upsertPoll(Poll poll) {
    state.polls[poll.id] = poll;
    state = state.copyWith();
  }

  /// Applies the local user's own vote optimistically (votePoll). No-op if the
  /// poll is unknown or the user already voted.
  bool applyLocalVote(String pollId, int optionIndex) {
    final poll = state.polls[pollId];
    if (poll == null) return false;
    if (poll.votes.containsKey(state.selfPubkey)) return false;
    poll.votes[state.selfPubkey] = optionIndex;
    state = state.copyWith();
    return true;
  }

  // -------------------------------------------------------------------------
  // Zaps (kind 9735 receipts) — per-message total + zappers.
  // -------------------------------------------------------------------------

  /// Ingests a kind-9735 zap receipt, accruing sats + the zapper to the zapped
  /// message's aggregate. Deduped by lowercased bolt11 (zaps.js
  /// `_recordMessageZap`). Only message zaps (with an `['e', …]` tag) accrue.
  void ingestZapReceipt(NostrEvent e) {
    final info = ZapLogic.parseReceipt(e);
    if (info == null) return;
    recordMessageZap(
      messageId: info.messageId,
      zapperPubkey: info.zapperPubkey,
      amountSats: info.amountSats,
      dedupKey: info.dedupKey,
    );
  }

  /// Records a zap against [messageId], deduped by [dedupKey]. Returns true when
  /// the zap was newly counted.
  bool recordMessageZap({
    required String messageId,
    required String zapperPubkey,
    required int amountSats,
    required String dedupKey,
  }) {
    if (messageId.isEmpty || amountSats <= 0) return false;
    final mz = state.zaps.putIfAbsent(messageId, MessageZaps.new);
    if (!mz.receipts.add(dedupKey)) return false;
    mz.totalSats += amountSats;
    mz.zappers.add(zapperPubkey);
    state = state.copyWith();
    return true;
  }

  // -------------------------------------------------------------------------
  // PM / group / presence ingest (called by the controller after gift-wrap
  // unwrap; decryption needs the privkey so it stays in the service/controller).
  // -------------------------------------------------------------------------

  /// Inserts a decrypted PM [m] (kind-14 rumor mapped via [PmLogic.mapPmRumor])
  /// into the `pm-<peer>` store, creating/refreshing the conversation. Dedups
  /// on event id and nymMessageId. Honors [closedPMs] for backlog.
  void ingestPMMessage(Message m) {
    final peer = m.conversationPubkey;
    if (peer == null) return;
    // A closed conversation only re-opens when a message strictly newer than
    // the close time arrives; older relay backlog is ignored (pms.js).
    if (_closedPMs.contains(peer)) {
      final closedAt = _closedPMTimes[peer] ?? 0;
      if (m.createdAt > closedAt) {
        _closedPMs.remove(peer);
        _closedPMTimes.remove(peer);
      } else {
        return;
      }
    }
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return;
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return;
    }
    m.seq = _nextIngestSeq();

    final key = m.conversationKey ?? PmLogic.pmStorageKey(peer);
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    list.add(m);
    list.sort(compareMessages);

    // Maintain the conversation meta entry.
    final convo = state.pmConversations.firstWhere(
      (c) => c.pubkey == peer,
      orElse: () {
        final c = PMConversation(pubkey: peer, nym: m.isOwn ? '' : m.author);
        state.pmConversations.add(c);
        return c;
      },
    );
    if (!m.isOwn && convo.nym.isEmpty) convo.nym = m.author;
    if (m.timestamp > convo.lastMessageTime) {
      convo.lastMessageTime = m.timestamp;
    }

    // Track the sender as a seen user.
    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      u.lastSeen = m.timestamp;
    }

    if (key != state.view.storageKey && !m.isOwn && !state.isMessageFiltered(m)) {
      state.unreadCounts[peer] = (state.unreadCounts[peer] ?? 0) + 1;
    }
    state = state.copyWith();
  }

  /// Inserts a decrypted group message [m] into the `group-<id>` store.
  void ingestGroupMessage(Message m) {
    final gid = m.groupId;
    if (gid == null) return;
    if (_leftGroups.contains(gid)) return;
    if (m.id.isNotEmpty && !_seenIds.add(m.id)) return;
    if (m.nymMessageId != null && !_seenNymMessageIds.add(m.nymMessageId!)) {
      return;
    }
    m.seq = _nextIngestSeq();

    final key = m.conversationKey ?? GroupLogic.groupStorageKey(gid);
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    list.add(m);
    list.sort(compareMessages);

    final idx = state.groups.indexWhere((g) => g.id == gid);
    if (idx >= 0 && m.timestamp > state.groups[idx].lastMessageTime) {
      state.groups[idx].lastMessageTime = m.timestamp;
    }
    if (!m.isOwn) {
      final u = state.users.putIfAbsent(
        m.pubkey,
        () => User(pubkey: m.pubkey, nym: m.author),
      );
      u.lastSeen = m.timestamp;
    }
    if (key != state.view.storageKey && !m.isOwn && !state.isMessageFiltered(m)) {
      // Key the unread count by the group's storage key (== `key`), NOT the bare
      // gid — the sidebar group row reads `unread[groupStorageKey(id)]`, so a
      // bare-gid write never surfaced as a badge.
      state.unreadCounts[key] = (state.unreadCounts[key] ?? 0) + 1;
    }
    state = state.copyWith();
  }

  /// Registers/updates a [Group] in the store (on create or on receiving a
  /// `group-invite`). Replaces any existing entry with the same id.
  void upsertGroup(Group group) {
    if (_leftGroups.contains(group.id)) return;
    final idx = state.groups.indexWhere((g) => g.id == group.id);
    if (idx >= 0) {
      state.groups[idx] = group;
    } else {
      state.groups.add(group);
    }
    state = state.copyWith();
  }

  /// Looks up a group by id (null if unknown).
  Group? groupById(String id) {
    for (final g in state.groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Applies a verified group control rumor to the named group, returning the
  /// outcome. Mutations (membership/roles/metadata) happen in place via
  /// [GroupLogic.applyControlEvent].
  GroupControlResult applyGroupControl({
    required String groupId,
    required String type,
    required List<List<String>> tags,
    required String senderPubkey,
    required int ts,
    String? eventId,
  }) {
    final g = groupById(groupId);
    if (g == null) return GroupControlResult.ignored;
    final result = GroupLogic.applyControlEvent(
      group: g,
      type: type,
      tags: tags,
      senderPubkey: senderPubkey,
      ts: ts,
      eventId: eventId,
      selfPubkey: state.selfPubkey,
    );
    if (result == GroupControlResult.applied) {
      // If we were removed, drop the group locally.
      if (type == 'group-remove-member' && !g.members.contains(state.selfPubkey)) {
        _leftGroups.add(groupId);
        state.groups.removeWhere((x) => x.id == groupId);
        state.messages.remove(GroupLogic.groupStorageKey(groupId));
      }
      state = state.copyWith();
    }
    return result;
  }

  /// Applies a parsed delivery/read [receipt] to our own outgoing message that
  /// shares its `nymMessageId`. Only advances delivery status, never regresses.
  void applyReceipt(ReceiptInfo receipt) {
    final target = receipt.messageId.toLowerCase();
    final next = PmLogic.deliveryFromReceipt(receipt.receiptType);
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.isOwn &&
            m.nymMessageId != null &&
            m.nymMessageId!.toLowerCase() == target) {
          if (PmLogic.statusOrder(next) > PmLogic.statusOrder(m.deliveryStatus)) {
            m.deliveryStatus = next;
            changed = true;
          }
        }
      }
    }
    if (changed) state = state.copyWith();
  }

  /// Marks [pubkey] as typing (or not) within [storageKey]. [expiresAtMs] is
  /// when the indicator auto-clears (typically now + ~4s).
  void setTyping({
    required String storageKey,
    required String pubkey,
    required bool typing,
    int? expiresAtMs,
  }) {
    final k = '$storageKey|$pubkey';
    if (typing) {
      state.typing[k] =
          expiresAtMs ?? DateTime.now().millisecondsSinceEpoch + 4000;
    } else {
      state.typing.remove(k);
    }
    state = state.copyWith();
  }

  /// Updates a user's presence from a kind-30078 nym-presence event (or a
  /// gift-wrapped friend-presence rumor).
  /// Applies a parsed nym-presence event to the user's store entry. Mirrors
  /// users.js `handlePresenceEvent`: updates status/away/nym, and — when the
  /// presence carries an `avatar-update` / `shop-update` — the avatar
  /// (`profile.picture`) and the broadcast shop cosmetics.
  ///
  /// `hidden` status updates `lastSeen`/away tracking but leaves the
  /// activity-derived [User.status] alone (the PWA tracks visibility separately,
  /// so a hidden user still appears in lists without a status dot — here
  /// [User.effectiveStatus] returns `hidden` directly when status is hidden).
  void setUserPresence({
    required String pubkey,
    required UserStatus status,
    String? nym,
    String? awayMessage,
    int? lastSeenMs,
    String? avatarUrl,
    bool hasAvatarTag = false,
    bool shopUpdate = false,
    String? shopStyle,
    String? shopFlair,
    bool isSupporter = false,
    List<String>? shopCosmetics,
    int? shopEdition,
  }) {
    final u = state.users.putIfAbsent(
      pubkey,
      () => User(pubkey: pubkey, nym: nym ?? getNymFromPubkey('anon', pubkey)),
    );
    u.status = status;
    if (nym != null && nym.isNotEmpty) u.nym = getNymFromPubkey(nym, pubkey);
    u.awayMessage = (awayMessage != null && awayMessage.isNotEmpty)
        ? awayMessage
        : (status == UserStatus.away ? u.awayMessage : null);
    if (lastSeenMs != null) u.lastSeen = lastSeenMs;

    // Avatar: an `avatar-update` tag sets (or clears, when empty) the picture
    // (users.js avatar branch). profile.picture is the canonical avatar source.
    if (hasAvatarTag) {
      if (avatarUrl != null && avatarUrl.isNotEmpty) {
        (u.profile ??= UserProfile()).picture = avatarUrl;
      } else {
        u.profile?.picture = null;
      }
    }

    // Shop cosmetics: a `shop-update` event refreshes the broadcast flair so it
    // renders for everyone (users.js shop-update branch → re-fetch; native reads
    // the inlined tags). Absent inlined tags, the cosmetics are cleared.
    if (shopUpdate) {
      u.shopStyle = (shopStyle != null && shopStyle.isNotEmpty) ? shopStyle : null;
      u.shopFlair = (shopFlair != null && shopFlair.isNotEmpty) ? shopFlair : null;
      u.isSupporter = isSupporter;
      // Special cosmetics + Genesis edition broadcast by other users
      // (`active.cosmetics`/`active.editions`, shop.js:459-478).
      u.shopCosmetics = shopCosmetics ?? const <String>[];
      u.shopEdition = shopEdition;
    }

    state = state.copyWith();
  }

  /// Records a closed PM conversation so its older backlog is ignored. Stamps
  /// the close time so a strictly-newer inbound message can re-open it (pms.js
  /// `closedPMTimes`). [nowSec] is injectable for tests.
  void closePM(String peerPubkey, {int? nowSec}) {
    _closedPMs.add(peerPubkey);
    _closedPMTimes[peerPubkey] =
        nowSec ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
    state.pmConversations.removeWhere((c) => c.pubkey == peerPubkey);
    state.messages.remove(PmLogic.pmStorageKey(peerPubkey));
    state = state.copyWith();
  }

  /// Opens (or creates) a PM conversation entry for [peerPubkey] without a
  /// message — used when starting a fresh thread from the UI.
  void ensurePMConversation(String peerPubkey, {String? nym}) {
    _closedPMs.remove(peerPubkey);
    _closedPMTimes.remove(peerPubkey);
    final exists = state.pmConversations.any((c) => c.pubkey == peerPubkey);
    if (!exists) {
      state.pmConversations.add(PMConversation(
        pubkey: peerPubkey,
        nym: nym ?? getNymFromPubkey('anon', peerPubkey),
        lastMessageTime: DateTime.now().millisecondsSinceEpoch,
      ));
      state = state.copyWith();
    }
  }

  void switchView(ChatView view) {
    // Clear unread for the target on entry (mirrors marking-as-read).
    state.unreadCounts.remove(view.id);
    state.unreadCounts.remove(view.storageKey);
    state = state.copyWith(view: view);
    // Best-effort D1 history backfill on open (channel-get / group archive).
    // Wrapped so a backfill failure can't break the view switch.
    final cb = onViewOpened;
    if (cb != null) {
      try {
        cb(view);
      } catch (_) {}
    }
  }

  // -------------------------------------------------------------------------
  // Social / moderation (docs/specs/03 §11) — friends, blocked users, blocked
  // keywords. The controller owns KV persistence (nym_friends / nym_blocked /
  // nym_blocked_keywords); this layer owns the in-memory Sets + filtering.
  // -------------------------------------------------------------------------

  /// Toggles [pubkey] in the friend set, returning the new state (true = now a
  /// friend). Mirrors users.js `toggleFriend`.
  bool toggleFriend(String pubkey) {
    if (pubkey.isEmpty) return state.friends.contains(pubkey);
    final bool nowFriend;
    if (state.friends.contains(pubkey)) {
      state.friends.remove(pubkey);
      nowFriend = false;
    } else {
      state.friends.add(pubkey);
      nowFriend = true;
    }
    state = state.copyWith();
    return nowFriend;
  }

  /// Adds [pubkey] to the friend set (idempotent).
  void addFriend(String pubkey) {
    if (pubkey.isEmpty) return;
    if (state.friends.add(pubkey)) state = state.copyWith();
  }

  /// Removes [pubkey] from the friend set.
  void removeFriend(String pubkey) {
    if (state.friends.remove(pubkey)) state = state.copyWith();
  }

  /// Blocks [pubkey] (users.js `toggleBlockUserByPubkey` add branch →
  /// `hideMessagesFromBlockedUser`). Returns true if newly blocked.
  bool blockUser(String pubkey) {
    if (pubkey.isEmpty) return false;
    final added = state.blockedUsers.add(pubkey);
    if (added) state = state.copyWith();
    return added;
  }

  /// Unblocks [pubkey] (users.js `unblockByPubkey`).
  bool unblockUser(String pubkey) {
    final removed = state.blockedUsers.remove(pubkey);
    if (removed) state = state.copyWith();
    return removed;
  }

  /// Idempotent blocked-user remover (settings "Blocked" list × button). Alias
  /// of [unblockUser] under the shared API contract name.
  void removeBlockedUser(String pubkey) => unblockUser(pubkey);

  /// Idempotent hidden-channel remover (settings "Hidden" list). Alias of
  /// [unhideChannel] under the shared API contract name.
  void removeHiddenChannel(String key) => unhideChannel(key);

  /// Idempotent blocked-channel remover (settings "Blocked Channels" list).
  /// Alias of [unblockChannel] under the shared API contract name.
  void removeBlockedChannel(String key) => unblockChannel(key);

  /// Toggles [pubkey]'s blocked state, returning the new state (true = blocked).
  bool toggleBlockUser(String pubkey) {
    if (state.blockedUsers.contains(pubkey)) {
      unblockUser(pubkey);
      return false;
    }
    blockUser(pubkey);
    return true;
  }

  /// Adds a blocked keyword (lowercased + trimmed; users.js `addBlockedKeyword`).
  /// Returns the normalized keyword if added, else null (empty / duplicate).
  String? addBlockedKeyword(String keyword) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isEmpty) return null;
    if (!state.blockedKeywords.add(kw)) return null;
    state = state.copyWith();
    return kw;
  }

  /// Removes a blocked keyword (users.js `removeBlockedKeyword`).
  bool removeBlockedKeyword(String keyword) {
    final removed = state.blockedKeywords.remove(keyword.toLowerCase());
    if (removed) state = state.copyWith();
    return removed;
  }

  /// Hydrates the social Sets from persisted KV state (boot). Keywords are
  /// lowercased to match the add-path normalization.
  void hydrateSocialState({
    Set<String>? friends,
    Set<String>? blockedUsers,
    Set<String>? blockedKeywords,
  }) {
    if (friends != null) state.friends.addAll(friends);
    if (blockedUsers != null) state.blockedUsers.addAll(blockedUsers);
    if (blockedKeywords != null) {
      state.blockedKeywords.addAll(blockedKeywords.map((k) => k.toLowerCase()));
    }
    state = state.copyWith();
  }

  /// Applies an edit to a stored message (channel/PM/group): replaces its
  /// content + flags it edited. Mirrors `publishEditedChannelMessage`'s local
  /// rewrite + the PM/group `editedMessages` apply. No-op if not found.
  bool applyLocalEdit(String messageId, String newContent) {
    var changed = false;
    for (final list in state.messages.values) {
      for (final m in list) {
        if (m.id == messageId || m.nymMessageId == messageId) {
          m.content = newContent;
          m.isEdited = true;
          changed = true;
        }
      }
    }
    if (changed) state = state.copyWith();
    return changed;
  }

  /// Removes a message locally (deletion request / mod delete). Mirrors
  /// `publishDeletionEvent`'s DOM + stored-message removal. Matches on both the
  /// event id and the nymMessageId (PM/group bubbles key on nymMessageId).
  bool removeMessage(String messageId) {
    var changed = false;
    for (final list in state.messages.values) {
      final before = list.length;
      list.removeWhere(
          (m) => m.id == messageId || m.nymMessageId == messageId);
      if (list.length != before) changed = true;
    }
    if (changed) state = state.copyWith();
    return changed;
  }

  /// Real reactor nyms for [messageId] / [emoji] (users.js reactor map). Exposes
  /// the private `_reactors` map so the reactors modal can show real names.
  List<String> reactorNyms(String messageId, String emoji) {
    final byEmoji = _reactors[messageId];
    if (byEmoji == null) return const [];
    final reactors = byEmoji[emoji];
    if (reactors == null) return const [];
    return reactors.values.where((n) => n.isNotEmpty).toList();
  }

  /// Reactor pubkey→nym map for [messageId] / [emoji] (null if none).
  Map<String, String>? reactorsFor(String messageId, String emoji) =>
      _reactors[messageId]?[emoji];

  // -------------------------------------------------------------------------
  // Channel management (docs/specs/03 §1.3–§1.6). Persistence to the KV list
  // sets is handled by the controller via the change callbacks; this layer owns
  // the in-memory `channels` registry + companion sets.
  // -------------------------------------------------------------------------

  /// Adds a channel to the registry if not present (`addChannel`). [geohash]
  /// non-empty marks a geohash channel. Returns the registered [ChannelEntry].
  ChannelEntry addChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    final existing = state.channels.where((c) => c.key == key);
    if (existing.isNotEmpty) return existing.first;
    final entry = ChannelEntry(channel: channel, geohash: geohash);
    state.channels.add(entry);
    state = state.copyWith();
    return entry;
  }

  /// Switches the active view to a channel, adding it first if unknown
  /// (`switchChannel`). [geohash] non-empty selects a geohash channel.
  void switchChannel(String channel, {String geohash = ''}) {
    final key = (geohash.isNotEmpty ? geohash : channel).toLowerCase();
    if (!state.channels.any((c) => c.key == key)) {
      addChannel(channel, geohash: geohash);
    }
    switchView(ChatView.channel(geohash.isNotEmpty ? geohash : channel));
  }

  /// Removes a channel from the registry (`removeChannel`). `#nymchat` cannot be
  /// removed. If the removed channel is active, switches to `#nymchat`. Returns
  /// true if a channel was removed.
  bool removeChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    final before = state.channels.length;
    state.channels.removeWhere((c) => c.key == k);
    state.pinnedChannels.remove(k);
    if (state.view.kind == ViewKind.channel && state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      state = state.copyWith();
    }
    return state.channels.length != before;
  }

  /// Toggles a channel's pinned (favorite) status (`togglePin`). `#nymchat` can
  /// neither be pinned nor unpinned — it is always treated as the top channel,
  /// so the toggle is a no-op for it (channels.js `togglePin`: early return for
  /// `'nymchat'`). Returns the new pinned state.
  bool togglePin(String key) {
    final k = key.toLowerCase();
    // #nymchat is always at the top; the PWA neither pins nor unpins it.
    if (k == kDefaultChannel) return state.pinnedChannels.contains(k);
    if (state.pinnedChannels.contains(k)) {
      state.pinnedChannels.remove(k);
      state = state.copyWith();
      return false;
    }
    state.pinnedChannels.add(k);
    state = state.copyWith();
    return true;
  }

  /// Hides a channel from the sidebar (`hiddenChannels`). `#nymchat` cannot be
  /// hidden (channels.js `toggleHideChannel`: early return for `'nymchat'`).
  /// Returns the new state.
  bool hideChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false; // #nymchat cannot be hidden
    final added = state.hiddenChannels.add(k);
    if (added) state = state.copyWith();
    return added;
  }

  /// Unhides a channel.
  void unhideChannel(String key) {
    if (state.hiddenChannels.remove(key.toLowerCase())) {
      state = state.copyWith();
    }
  }

  /// Blocks a channel from discovery and removes it from the sidebar
  /// (`blockChannel`). `#nymchat` cannot be blocked. If the blocked channel is
  /// active, switches to `#nymchat`.
  bool blockChannel(String key) {
    final k = key.toLowerCase();
    if (k == kDefaultChannel) return false;
    state.blockedChannels.add(k);
    state.channels.removeWhere((c) => c.key == k);
    state.pinnedChannels.remove(k);
    if (state.view.kind == ViewKind.channel && state.view.id.toLowerCase() == k) {
      switchView(const ChatView.channel(kDefaultChannel));
    } else {
      state = state.copyWith();
    }
    return true;
  }

  /// Unblocks a channel and re-adds it to the registry.
  void unblockChannel(String key, {String geohash = ''}) {
    final k = key.toLowerCase();
    if (state.blockedChannels.remove(k)) {
      addChannel(geohash.isNotEmpty ? geohash : key, geohash: geohash);
    }
  }

  /// Hydrates the channel companion sets/maps from persisted KV state (boot).
  void hydrateChannelState({
    Set<String>? pinned,
    Set<String>? hidden,
    Set<String>? blocked,
    Map<String, int>? unreadCounts,
    Map<String, int>? lastActivity,
    List<ChannelEntry>? joinedChannels,
  }) {
    if (pinned != null) state.pinnedChannels.addAll(pinned);
    if (hidden != null) state.hiddenChannels.addAll(hidden);
    if (blocked != null) state.blockedChannels.addAll(blocked);
    if (unreadCounts != null) state.unreadCounts.addAll(unreadCounts);
    if (lastActivity != null) state.channelLastActivity.addAll(lastActivity);
    if (joinedChannels != null) {
      for (final c in joinedChannels) {
        if (state.blockedChannels.contains(c.key)) continue;
        if (!state.channels.any((x) => x.key == c.key)) {
          state.channels.add(c);
        }
      }
    }
    state = state.copyWith();
  }

  /// Hydrates cached messages for a channel/PM/group key (boot from CacheStore).
  void hydrateMessages(String key, List<Message> msgs) {
    if (msgs.isEmpty) return;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    for (final m in msgs) {
      if (m.id.isNotEmpty && !_seenIds.add(m.id)) continue;
      m.seq = _nextIngestSeq();
      list.add(m);
    }
    list.sort(compareMessages);
    state = state.copyWith();
  }

  /// Hydrates cached profiles into the user store (boot from CacheStore).
  void hydrateProfiles(Map<String, UserProfile> profiles) {
    profiles.forEach((pubkey, p) {
      final existing = state.users[pubkey];
      if (existing != null) {
        if (existing.profile == null ||
            p.kind0Ts >= existing.profile!.kind0Ts) {
          existing.profile = p;
          if ((p.name ?? '').isNotEmpty) {
            existing.nym = getNymFromPubkey(p.name!, pubkey);
          }
        }
      } else {
        state.users[pubkey] = User(
          pubkey: pubkey,
          nym: getNymFromPubkey(p.name ?? 'anon', pubkey),
          profile: p,
        );
      }
    });
    state = state.copyWith();
  }

  /// Hydrates cached reactions (entries shape `[[emoji,[[reactor,nym]]]]`) into
  /// the reactor map and recomputes tallies (boot from CacheStore).
  void hydrateReactions(Map<String, List<dynamic>> entriesByMessage) {
    entriesByMessage.forEach((messageId, entries) {
      final byEmoji = _reactors.putIfAbsent(messageId, () => {});
      for (final e in entries) {
        if (e is! List || e.length < 2) continue;
        final emoji = e[0].toString();
        final reactors = e[1];
        if (reactors is! List) continue;
        final map = byEmoji.putIfAbsent(emoji, () => {});
        for (final r in reactors) {
          if (r is List && r.isNotEmpty) {
            map[r[0].toString()] = r.length > 1 ? r[1].toString() : '';
          }
        }
      }
      _recomputeReactionTally(messageId);
    });
    state = state.copyWith();
  }

  /// Snapshot of reactions in the CacheStore `entries` shape, for flushing.
  Map<String, List<dynamic>> reactionEntriesSnapshot() {
    final out = <String, List<dynamic>>{};
    _reactors.forEach((messageId, byEmoji) {
      final entries = <dynamic>[];
      byEmoji.forEach((emoji, reactors) {
        entries.add([
          emoji,
          reactors.entries.map((e) => [e.key, e.value]).toList(),
        ]);
      });
      if (entries.isNotEmpty) out[messageId] = entries;
    });
    return out;
  }

  /// Records channel activity (used by send paths) so the sort floats it up.
  void touchChannelActivity(String storageKey, {int? ms}) {
    state.channelLastActivity[storageKey] =
        ms ?? DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith();
  }

  /// Appends a locally-echoed self message to the current view (composer SEND).
  /// For PM/group sends, pass [nymMessageId] so inbound receipts can match it
  /// and advance the delivery ticks. Returns the appended [Message].
  Message? sendLocal(String text,
      {String? nymMessageId, String? pubkeyOverride, String? authorOverride}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final view = state.view;
    final list = state.messages.putIfAbsent(view.storageKey, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nowSec = nowMs ~/ 1000;
    // [pubkeyOverride]/[authorOverride] are the pseudonymous-send path: the
    // optimistic echo carries the per-message ephemeral pubkey + random anon
    // nym instead of the durable identity (publishMessagePseudonymous).
    final m = Message(
      id: '_optim_${_nextLocalSeq().toRadixString(36)}',
      pubkey: pubkeyOverride ?? state.selfPubkey,
      author: authorOverride ?? state.selfNym,
      content: trimmed,
      createdAt: nowSec,
      ms: nowMs,
      seq: _localSeq,
      isOwn: true,
      isPM: view.kind == ViewKind.pm,
      isGroup: view.kind == ViewKind.group,
      groupId: view.kind == ViewKind.group ? view.id : null,
      channel: view.kind == ViewKind.channel ? view.id : null,
      conversationKey: view.kind != ViewKind.channel ? view.storageKey : null,
      conversationPubkey: view.kind == ViewKind.pm ? view.id : null,
      nymMessageId: nymMessageId,
      deliveryStatus: DeliveryStatus.sent,
      senderVerified: true,
    );
    list.add(m);
    m.optimistic = true;
    if (nymMessageId != null) _seenNymMessageIds.add(nymMessageId);
    // New list identity so listeners rebuild.
    state = state.copyWith();
    return m;
  }

  /// Reconciles an optimistic channel echo with its real signed event, mirroring
  /// the PWA's `_replaceOptimisticMessage` (messages.js:148). Finds the locally
  /// echoed message by its temp id [optimisticId], rewrites its id (and
  /// created_at / ms) to the signed event's values IN PLACE, clears the
  /// `optimistic` flag, and — crucially — registers [realId] in [_seenIds] so the
  /// relay echo that arrives later (carrying the same real id) is deduped instead
  /// of appended as a duplicate. Re-sorts the list when the timestamp shifted
  /// (PoW mining can move created_at). No-op if the optimistic message is gone
  /// (e.g. the user already switched/cleared the view).
  ///
  /// Channel messages have no shared `nymMessageId`, so without this the
  /// `_optim_*` echo and the relay-echoed real-id event would both render — the
  /// double-send the user reported. PM/group sends already dedupe via
  /// [_seenNymMessageIds]; this is the channel analogue.
  void replaceOptimistic(
    String optimisticId,
    String realId, {
    int? realCreatedAt,
    int? realMs,
  }) {
    if (realId.isEmpty) return;
    // Register the real id first so even a relay echo that races ahead of this
    // call (already appended) can't slip a second copy through afterwards.
    final alreadySeen = !_seenIds.add(realId);
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      final m = list[idx];
      // If a relay echo with the real id already landed (rare race), drop the
      // optimistic placeholder rather than keep a duplicate.
      if (alreadySeen && list.any((x) => x.id == realId && !identical(x, m))) {
        list.removeAt(idx);
        state = state.copyWith();
        return;
      }
      final oldCreated = m.createdAt;
      m.id = realId;
      if (realCreatedAt != null && realCreatedAt > 0) {
        m.createdAt = realCreatedAt;
        m.timestamp = realCreatedAt * 1000;
      }
      if (realMs != null && realMs > 0) m.ms = realMs;
      m.optimistic = false;
      if (oldCreated != m.createdAt) list.sort(compareMessages);
      state = state.copyWith();
      return;
    }
    // Optimistic message no longer present; the real id is registered so the
    // relay echo still won't double up.
    state = state.copyWith();
  }

  /// Marks an optimistic channel echo as failed (PWA `_markOptimisticFailed`,
  /// messages.js:208): the publish threw, so the placeholder stays but flips to
  /// the failed delivery state. No-op if the message is gone.
  void markOptimisticFailed(String optimisticId) {
    for (final list in state.messages.values) {
      final idx = list.indexWhere((m) => m.id == optimisticId);
      if (idx < 0) continue;
      list[idx].deliveryStatus = DeliveryStatus.failed;
      state = state.copyWith();
      return;
    }
  }

  /// Injects a centered system/action pill into a conversation's message flow,
  /// mirroring `displaySystemMessage(content, type)` (`messages.js:1511`). Routes
  /// to [storageKey] when given, else the active view. Pass [action] for the
  /// purple-italic `.action-message` variant. This is the in-list sink for
  /// command feedback, P2P/call status, flood notices, etc.
  void addSystemMessage(String content, {bool action = false, String? storageKey}) {
    if (content.isEmpty) return;
    final key = storageKey ?? state.view.storageKey;
    final list = state.messages.putIfAbsent(key, () => <Message>[]);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    list.add(Message.system(content, action: action, createdAtMs: nowMs)
      ..seq = _nextLocalSeq());
    state = state.copyWith();
  }
}

final appStateProvider =
    StateNotifierProvider<AppStateNotifier, AppState>((ref) {
  return AppStateNotifier();
});

/// The active [ChatView].
final currentViewProvider = Provider<ChatView>((ref) {
  return ref.watch(appStateProvider).view;
});

/// Registered channels (sidebar PUBLIC CHANNELS).
final channelsProvider = Provider<List<ChannelEntry>>((ref) {
  return ref.watch(appStateProvider).channels;
});

/// PM conversations, most-recent first (sidebar PRIVATE MESSAGES).
final pmListProvider = Provider<List<PMConversation>>((ref) {
  final pms = [...ref.watch(appStateProvider).pmConversations];
  pms.sort((a, b) => b.lastMessageTime - a.lastMessageTime);
  return pms;
});

/// Groups (also surfaced under PRIVATE MESSAGES).
final groupsProvider = Provider<List<Group>>((ref) {
  return ref.watch(appStateProvider).groups;
});

/// Users keyed by pubkey (sidebar ONLINE NYMS source). Blocked users and
/// keyword-matched nyms are filtered out (users.js `updateUserList`:
/// `if (blockedUsers.has(pubkey)) return;` and the nym keyword guard).
final usersProvider = Provider<Map<String, User>>((ref) {
  final s = ref.watch(appStateProvider);
  if (s.blockedUsers.isEmpty && s.blockedKeywords.isEmpty) return s.users;
  final out = <String, User>{};
  s.users.forEach((pubkey, user) {
    if (pubkey == s.selfPubkey) {
      out[pubkey] = user;
      return;
    }
    if (s.blockedUsers.contains(pubkey)) return;
    if (s.blockedKeywords.isNotEmpty && s.hasBlockedKeyword('', user.nym)) {
      return;
    }
    out[pubkey] = user;
  });
  return out;
});

/// Ordered messages for the active view (oldest first). Messages from blocked
/// users and keyword matches (content OR author nym) are dropped — mirrors the
/// PWA's `.message.blocked` hiding (messages.js §11).
final messagesForCurrentViewProvider = Provider<List<Message>>((ref) {
  final s = ref.watch(appStateProvider);
  final list = s.messages[s.view.storageKey] ?? const <Message>[];
  final visible = (s.blockedUsers.isEmpty && s.blockedKeywords.isEmpty)
      ? [...list]
      : list.where((m) => !s.isMessageFiltered(m)).toList();
  visible.sort(compareMessages);
  return visible;
});

/// Reactions for the active view's messages (message id → tallies).
final reactionsProvider = Provider<Map<String, List<MessageReaction>>>((ref) {
  return ref.watch(appStateProvider).reactions;
});

/// Unread counts (channel key / pm pubkey / group id → count).
final unreadCountsProvider = Provider<Map<String, int>>((ref) {
  return ref.watch(appStateProvider).unreadCounts;
});

/// Pubkeys currently typing in the active view (non-expired indicators).
final typingForCurrentViewProvider = Provider<List<String>>((ref) {
  final s = ref.watch(appStateProvider);
  final prefix = '${s.view.storageKey}|';
  final now = DateTime.now().millisecondsSinceEpoch;
  final out = <String>[];
  s.typing.forEach((k, expiry) {
    if (k.startsWith(prefix) && expiry > now) {
      out.add(k.substring(prefix.length));
    }
  });
  return out;
});

/// Polls visible in the active channel view (geohash match), time-ordered.
/// Polls are channel-only (docs/specs/03 §6) — returns empty in PM/group views.
final pollsForCurrentViewProvider = Provider<List<Poll>>((ref) {
  final s = ref.watch(appStateProvider);
  if (s.view.kind != ViewKind.channel) return const [];
  final geohash = s.view.id;
  final out = s.polls.values.where((p) => p.geohash == geohash).toList()
    ..sort((a, b) => a.createdAt - b.createdAt);
  return out;
});

/// Per-message zap aggregates (message id → total sats + zappers).
final zapsProvider = Provider<Map<String, MessageZaps>>((ref) {
  return ref.watch(appStateProvider).zaps;
});

/// Friended pubkeys (`nym_friends`) — settings FRIENDS list + friend badges.
final friendsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).friends;
});

/// Blocked-user pubkeys (`nym_blocked`) — settings BLOCKED list.
final blockedUsersProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedUsers;
});

/// Blocked keywords (`nym_blocked_keywords`, lowercased) — settings list.
final blockedKeywordsProvider = Provider<Set<String>>((ref) {
  return ref.watch(appStateProvider).blockedKeywords;
});

/// The user's resolved geolocation for proximity sorting (set by the location
/// service / UI). Null when unavailable or permission denied.
final userLocationProvider = StateProvider<UserLocation?>((ref) => null);

/// Registered channels sorted by the PWA's priority (nymchat → active → pinned →
/// proximity → activity/unread), with hidden/blocked channels filtered out.
final sortedChannelsProvider = Provider<List<ChannelEntry>>((ref) {
  final s = ref.watch(appStateProvider);
  final sortByProximity = ref.watch(
      settingsProvider.select((settings) => settings.sortByProximity));
  // `hideNonPinned` (settings.js `hideNonPinnedChannels`): when on, the sidebar
  // shows only pinned channels (the default channel always stays visible).
  final hideNonPinned =
      ref.watch(settingsProvider.select((settings) => settings.hideNonPinned));
  final location = ref.watch(userLocationProvider);
  final visible = s.channels
      .where((c) => !s.hiddenChannels.contains(c.key))
      .where((c) => !s.blockedChannels.contains(c.key))
      .where((c) => !(hideNonPinned &&
          c.key != kDefaultChannel &&
          !s.pinnedChannels.contains(c.key)))
      .toList();
  return ChannelManager.sortChannels(
    visible,
    ChannelSortContext(
      activeKey:
          s.view.kind == ViewKind.channel ? s.view.id.toLowerCase() : '',
      pinned: s.pinnedChannels,
      lastActivity: s.channelLastActivity,
      unreadCounts: s.unreadCounts,
      sortByProximity: sortByProximity,
      userLocation: location,
    ),
  );
});

// =============================================================================
// Recent emojis (shared API contract). The current recents `List<String>` plus
// `record(emoji)`, backed by the persisted [EmojiRecentsStore]. Consumed by the
// quick-react popup, the emoji/reactions pickers, and the call reactions bar.
// Mirrors reactions.js `addToRecentEmojis`/`loadRecentEmojis`.
// =============================================================================

class RecentEmojisNotifier extends StateNotifier<List<String>> {
  RecentEmojisNotifier(this._ref) : super(const []) {
    _hydrate();
  }

  final Ref _ref;
  EmojiRecentsStore? _store;

  Future<void> _hydrate() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _store = EmojiRecentsStore(prefs);
      final loaded = _store!.load();
      if (mounted && loaded.isNotEmpty) state = loaded;
    } catch (_) {
      // Recents are best-effort; an unavailable store just yields empty recents.
    }
  }

  /// Records [emoji] as the most-recent (dedupe + prepend + cap), updating the
  /// in-memory list immediately and persisting in the background.
  void record(String emoji) {
    if (emoji.isEmpty) return;
    state = addRecentEmoji(state, emoji);
    final store = _store;
    if (store != null) {
      // Persist (the store re-derives from its own load, so just fire it).
      store.add(emoji);
    } else {
      // Store not hydrated yet — hydrate, then persist this pick.
      _persistWhenReady(emoji);
    }
  }

  Future<void> _persistWhenReady(String emoji) async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _store = EmojiRecentsStore(prefs);
      await _store!.add(emoji);
    } catch (_) {}
  }
}

/// The user's recent emojis (most-recent-first). Read the list directly;
/// `ref.read(recentEmojisProvider.notifier).record(emoji)` to bump one.
final recentEmojisProvider =
    StateNotifierProvider<RecentEmojisNotifier, List<String>>(
  (ref) => RecentEmojisNotifier(ref),
);

// =============================================================================
// Notification history (shared API contract). A 24h-trimmed list of recent
// notification entries with an unread count, mirroring the PWA's
// `notificationHistory` (`notifications.js:5-114`). Fed by message notifications
// and missed/declined calls; read by the shell bell badge + notifications modal.
// =============================================================================

/// One entry in the notification history.
class NotificationEntry {
  NotificationEntry({
    required this.type,
    required this.title,
    required this.body,
    required this.ts,
    this.route,
    this.eventId,
    this.senderPubkey,
    this.contextLabel,
    this.viewed = false,
  });

  /// `'message' | 'mention' | 'reaction' | 'call' | 'pm' | 'group' | …`.
  final String type;
  final String title;
  final String body;

  /// Milliseconds since epoch.
  final int ts;

  /// An opaque route/target the UI can use to navigate on tap (e.g. a PM pubkey,
  /// a channel key, or a group id). Null when not actionable.
  final String? route;

  /// The source event id (channel event id / PM nymMessageId / reaction id),
  /// used to dedup live + replayed copies (notifications.js `eventId`).
  final String? eventId;

  /// The sender's pubkey (notifications.js `senderPubkey`), used in the
  /// no-eventId dedup fallback.
  final String? senderPubkey;

  /// The PWA footer context label derived from `channelInfo` — `in #<geohash>`
  /// for a channel/geohash source or `in <GroupName>` for a group (notifications
  /// .js:519-533). Null for PM/mention sources, which the panel labels from the
  /// type. Preferred by the panel over the type-derived label when present.
  final String? contextLabel;
  bool viewed;
}

class NotificationHistoryState {
  const NotificationHistoryState({this.entries = const [], this.unread = 0});

  final List<NotificationEntry> entries;
  final int unread;

  NotificationHistoryState copyWith({
    List<NotificationEntry>? entries,
    int? unread,
  }) =>
      NotificationHistoryState(
        entries: entries ?? this.entries,
        unread: unread ?? this.unread,
      );
}

class NotificationHistoryNotifier
    extends StateNotifier<NotificationHistoryState> {
  NotificationHistoryNotifier() : super(const NotificationHistoryState());

  static const int _maxAgeMs = 24 * 60 * 60 * 1000; // 24h
  static const int _cap = 100;

  /// Records a notification, trimming entries older than 24h and capping the
  /// list. Increments the unread count. Mirrors `showNotification`'s history
  /// push + `_updateNotificationBadge` (`notifications.js:5-114`).
  ///
  /// Deduped like the PWA (notifications.js:27-36): a matching [eventId], or the
  /// same title+body+sender within 60s, is dropped — so a live notification and
  /// its archive/replay copy don't both land.
  void record({
    required String type,
    required String title,
    required String body,
    String? route,
    int? ts,
    String? eventId,
    String? senderPubkey,
    String? contextLabel,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final stamp = ts ?? now;

    // Dedup against existing history (live + replay can both fire).
    final isDupe = state.entries.any((e) {
      if (eventId != null &&
          eventId.isNotEmpty &&
          e.eventId != null &&
          e.eventId == eventId) {
        return true;
      }
      return e.title == title &&
          e.body == body &&
          (e.senderPubkey ?? '') == (senderPubkey ?? '') &&
          (e.ts - stamp).abs() < 60000;
    });
    if (isDupe) return;

    final entry = NotificationEntry(
      type: type,
      title: title,
      body: body,
      ts: stamp,
      route: route,
      eventId: eventId,
      senderPubkey: senderPubkey,
      contextLabel: contextLabel,
    );
    final kept = [
      entry,
      ...state.entries.where((e) => now - e.ts < _maxAgeMs),
    ];
    if (kept.length > _cap) kept.removeRange(_cap, kept.length);
    final unread = kept.where((e) => !e.viewed).length;
    state = NotificationHistoryState(entries: kept, unread: unread);
  }

  /// Marks every entry viewed and zeroes the unread count (modal opened).
  void markAllViewed() {
    for (final e in state.entries) {
      e.viewed = true;
    }
    state = state.copyWith(entries: List.of(state.entries), unread: 0);
  }

  /// Clears the history entirely.
  void clear() => state = const NotificationHistoryState();
}

/// The notification history store. The shell reads `.unread` for the bell badge;
/// the notifications modal reads `.entries`. Feed it via
/// `ref.read(notificationHistoryProvider.notifier).record(...)`.
final notificationHistoryProvider = StateNotifierProvider<
    NotificationHistoryNotifier, NotificationHistoryState>(
  (ref) => NotificationHistoryNotifier(),
);

// =============================================================================
// Live custom emoji (NIP-30). The PWA discovers custom emoji from three sources
// (emoji.js): kind-30030 emoji packs, the user's kind-10030 emoji-pack list, and
// loose `['emoji', shortcode, url]` tags on any incoming event. This notifier is
// the live, mutable store the [NostrController] feeds as those events arrive; it
// hydrates from + persists to the same `nym_custom_emojis` / `nym_custom_emoji_packs`
// SharedPreferences keys the PWA uses, so the cache survives reloads.
//
// The picker reads [customEmojiStateProvider] (a default-empty `Provider`). This
// notifier exposes the SAME [CustomEmojiState] shape via [liveCustomEmojiProvider]
// so the emoji UI can read live updates (CROSS-FILE: the picker/composer should
// watch this provider, or override `customEmojiStateProvider` from it, to surface
// relay-sourced packs/codes — they currently load only the static cache).
// =============================================================================

final RegExp _kEmojiShortcodeRx = RegExp(r'^[a-zA-Z0-9_]+$');
final RegExp _kEmojiUrlRx = RegExp(r'^https?://', caseSensitive: false);

class LiveCustomEmojiNotifier extends StateNotifier<CustomEmojiState> {
  LiveCustomEmojiNotifier(this._ref) : super(CustomEmojiState.empty) {
    _hydrate();
  }

  final Ref _ref;
  SharedPreferences? _prefs;

  /// Loose shortcode → url (mirrors `customEmojis`). Mutable working copy; the
  /// published [state] is rebuilt from this + [_packsByKey] on each change.
  final Map<String, String> _codeToUrl = {};

  /// Pack key (`pubkey:identifier`) → pack (mirrors `customEmojiPacks`).
  final Map<String, CustomEmojiPack> _packsByKey = {};

  /// `30030:<pubkey>:<identifier>` refs the user subscribes to (kind-10030
  /// `userEmojiPackRefs`). Newest list wins (guarded by [_userListTs]).
  final Set<String> _userPackRefs = {};
  int _userListTs = 0;

  /// Hydrates from the persisted PWA cache so previously-seen emoji render
  /// immediately on launch (emoji.js `_loadCustomEmojiCache`).
  Future<void> _hydrate() async {
    try {
      final prefs = await _ref.read(emojiPrefsProvider.future);
      _prefs = prefs;
      final cached = loadCustomEmojiState(prefs);
      _codeToUrl.addAll(cached.codeToUrl);
      for (final p in cached.packs) {
        _packsByKey[p.key] = p;
      }
      if (mounted && (_codeToUrl.isNotEmpty || _packsByKey.isNotEmpty)) {
        _publish();
      }
    } catch (_) {
      // Cache is best-effort; an unavailable store just yields live-only emoji.
    }
  }

  /// Registers a loose custom emoji (emoji.js `registerCustomEmoji`): valid
  /// shortcode + http(s) url, never shadowing a built-in unicode shortcode.
  /// Returns true if it was newly added or changed.
  bool registerEmoji(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) || !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    // Cap the loose map like the PWA (`_saveCustomEmojiMap` keeps the last 5000).
    if (_codeToUrl.length > 5000) {
      final keys = _codeToUrl.keys.toList();
      for (final k in keys.sublist(0, _codeToUrl.length - 5000)) {
        _codeToUrl.remove(k);
      }
    }
    _publish();
    _persist();
    return true;
  }

  /// Ingests `['emoji', shortcode, url]` tags from any inbound event
  /// (emoji.js `ingestEmojiTags`).
  void ingestEmojiTags(List<List<String>> tags) {
    var changed = false;
    for (final t in tags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        if (registerEmojiQuiet(t[1], t[2])) changed = true;
      }
    }
    if (changed) {
      _publish();
      _persist();
    }
  }

  /// Like [registerEmoji] but defers the publish/persist (used by batch ingest).
  bool registerEmojiQuiet(String? shortcode, String? url) {
    if (shortcode == null || url == null) return false;
    if (!_kEmojiShortcodeRx.hasMatch(shortcode) || !_kEmojiUrlRx.hasMatch(url)) {
      return false;
    }
    if (kEmojiShortcodeMap.containsKey(shortcode.toLowerCase())) return false;
    if (_codeToUrl[shortcode] == url) return false;
    _codeToUrl[shortcode] = url;
    return true;
  }

  /// Stores a kind-30030 emoji pack (emoji.js `_storeEmojiPack` /
  /// `handleEmojiPackEvent`): newest `created_at` wins per `pubkey:identifier`
  /// key, each pack emoji is registered into the loose map. Persists.
  void storePack(CustomEmojiPack pack) {
    if (pack.pubkey.isEmpty || pack.emojis.isEmpty) return;
    final existing = _packsByKey[pack.key];
    if (existing != null && existing.createdAt >= pack.createdAt) return;
    _packsByKey[pack.key] = pack;
    for (final e in pack.emojis) {
      registerEmojiQuiet(e.shortcode, e.url);
    }
    _publish();
    _persist();
  }

  /// Records the user's kind-10030 emoji-pack subscription list (emoji.js
  /// `handleUserEmojiListEvent`): newest event wins; any inline `emoji` tags are
  /// also registered. [refs] are the `30030:<pubkey>:<identifier>` `a`-tag values.
  void setUserPackRefs(List<String> refs, int createdAt,
      {List<List<String>> inlineEmojiTags = const []}) {
    if (createdAt < _userListTs) return;
    _userListTs = createdAt;
    _userPackRefs
      ..clear()
      ..addAll(refs);
    var changed = false;
    for (final t in inlineEmojiTags) {
      if (t.length >= 3 && t[0] == 'emoji') {
        if (registerEmojiQuiet(t[1], t[2])) changed = true;
      }
    }
    if (changed) {
      _publish();
      _persist();
    }
  }

  /// Whether [pack] is one the user subscribed to via their kind-10030 list.
  bool isPackSubscribed(CustomEmojiPack pack) =>
      _userPackRefs.contains('30030:${pack.pubkey}:${pack.identifier}');

  /// NIP-30 `['emoji', shortcode, url]` tags for every known custom shortcode
  /// used in [content] (emoji.js `customEmojiTagsForContent`). Lets an outgoing
  /// message declare its custom emoji so other clients render them. Empty when no
  /// known shortcodes appear.
  List<List<String>> emojiTagsForContent(String content) {
    if (content.isEmpty || _codeToUrl.isEmpty) return const [];
    final out = <List<String>>[];
    final added = <String>{};
    for (final m in RegExp(r':([a-zA-Z0-9_]+):').allMatches(content)) {
      final code = m.group(1)!;
      if (added.contains(code)) continue;
      final url = _codeToUrl[code];
      if (url != null) {
        added.add(code);
        out.add(['emoji', code, url]);
      }
    }
    return out;
  }

  /// Clears all live + persisted custom emoji (sign-out).
  void clearAll() {
    _codeToUrl.clear();
    _packsByKey.clear();
    _userPackRefs.clear();
    _userListTs = 0;
    if (mounted) state = CustomEmojiState.empty;
    final prefs = _prefs;
    if (prefs != null) {
      prefs.remove(kCustomEmojiMapKey);
      prefs.remove(kCustomEmojiPacksKey);
    }
  }

  /// Rebuilds the published immutable snapshot (newest packs first).
  void _publish() {
    if (!mounted) return;
    final packs = _packsByKey.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    state = CustomEmojiState(
      codeToUrl: Map.unmodifiable(_codeToUrl),
      packs: List.unmodifiable(packs),
    );
  }

  /// Persists both caches in the PWA's localStorage shape (`_saveCustomEmojiMap`
  /// + `_saveCustomEmojiCache`): the loose map as `[[shortcode,url],…]` (≤5000)
  /// and packs as objects sorted newest-first (≤200). Best-effort.
  void _persist() {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final mapEntries = _codeToUrl.entries
          .map((e) => [e.key, e.value])
          .toList();
      prefs.setString(kCustomEmojiMapKey, jsonEncode(mapEntries));
      final packs = _packsByKey.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final capped = packs.length > 200 ? packs.sublist(0, 200) : packs;
      final packJson = capped
          .map((p) => {
                'pubkey': p.pubkey,
                'identifier': p.identifier,
                'title': p.title,
                'created_at': p.createdAt,
                'emojis': p.emojis
                    .map((e) => {'shortcode': e.shortcode, 'url': e.url})
                    .toList(),
              })
          .toList();
      prefs.setString(kCustomEmojiPacksKey, jsonEncode(packJson));
    } catch (_) {
      // Quota or serialization failures are non-fatal; live state still works.
    }
  }
}

/// The live custom-emoji store, fed by the [NostrController]'s NIP-30
/// subscription (kinds 10030 + 30030) and inbound `emoji` tags. Read the
/// [CustomEmojiState] directly for the shortcode→url map + loaded packs.
final liveCustomEmojiProvider =
    StateNotifierProvider<LiveCustomEmojiNotifier, CustomEmojiState>(
  (ref) => LiveCustomEmojiNotifier(ref),
);
