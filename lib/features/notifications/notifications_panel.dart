// notifications_panel.dart - In-app notification history modal
// (`#notificationsModal` + `openNotificationsModal`, notifications.js:439-592).
//
// Foundations ships the STORE (`notificationHistoryProvider`); this builds the
// modal UI that renders its entries (avatar + decorated author wrapped in
// `<…>` brackets + body + context label + timestamp), highlights unread rows
// (cyan wash + primary left rule), exposes a "Mark all read" action, and opens
// the source conversation on tap (notifications.js:559-585). The shell owns the
// bell + badge and calls [showNotificationsPanel].
//
// Rendered as a centered `.modal` (showDialog) with shared modal chrome: 22px
// UPPERCASE primary header + bottom rule, 32px circular glass close chip.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/common/nym_avatar.dart';
import '../calls/call_nym.dart';
import '../messages/format/message_content.dart';

/// Opens the notifications history as a centered modal (the PWA renders it as a
/// `.modal` overlay).
///
/// The shell clears the unread badge right after this returns (`markAllViewed`,
/// chat_pane), which mutates the live entries' `viewed` flags. To keep the cyan
/// unread rule + "Mark all read" visible while the modal is up (the PWA shows
/// what was unread and only deducts the badge as items scroll past), we SNAPSHOT
/// each entry's unread state HERE — synchronously, before `showDialog` and thus
/// before the shell's `markAllViewed` runs — and hand the frozen rows to the
/// panel. The badge itself still zeroes on open, matching the PWA.
Future<void> showNotificationsPanel(BuildContext context) {
  // Read the store before showDialog so the snapshot precedes the shell's
  // on-open markAllViewed() (which flips the same entries' `viewed` bools).
  // Newest-first; the store already trims to 24h and caps the list.
  final entries =
      ProviderScope.containerOf(context).read(notificationHistoryProvider).entries;
  // Freeze the unread state per entry as a parallel list of bools (a public
  // type, so the widget constructor doesn't leak a private one).
  final viewedAtOpen = [for (final e in entries) e.viewed];
  // `.modal` barrier: solid-ui (default) dark `rgba(0,0,0,0.75)` →
  // `body.solid-ui.light-mode .modal { rgba(0,0,0,0.45) }`
  // (styles-themes-responsive.css:1630-1635).
  final isLight = context.nym.isLight;
  return showDialog<void>(
    context: context,
    barrierColor: isLight
        ? const Color(0x73000000) // black @ 0.45
        : const Color(0xBF000000), // black @ 0.75
    builder: (_) => NotificationsPanel(
      entries: entries,
      viewedAtOpen: viewedAtOpen,
    ),
  );
}

class NotificationsPanel extends ConsumerStatefulWidget {
  const NotificationsPanel({
    super.key,
    required this.entries,
    required this.viewedAtOpen,
  });

  /// Entries snapshotted at open (newest-first).
  final List<NotificationEntry> entries;

  /// Each entry's `viewed` state frozen at open, parallel to [entries] (see
  /// [showNotificationsPanel]) — used instead of the live (now-cleared) flags.
  final List<bool> viewedAtOpen;

  @override
  ConsumerState<NotificationsPanel> createState() => _NotificationsPanelState();
}

class _NotificationsPanelState extends ConsumerState<NotificationsPanel> {
  late final List<_NotifRow> _rows = [
    for (var i = 0; i < widget.entries.length; i++)
      _NotifRow(widget.entries[i], widget.viewedAtOpen[i]),
  ];

  /// Drives the "Mark all read" button + per-row highlight locally so the modal
  /// reflects the action immediately without a provider round-trip.
  late bool _hasUnread = _rows.any((r) => !r.viewed);

  void _markAllRead() {
    ref.read(notificationHistoryProvider.notifier).markAllViewed();
    setState(() {
      for (final r in _rows) {
        r.viewed = true;
      }
      _hasUnread = false;
    });
  }

  /// Opens the source conversation for [entry] and closes the modal
  /// (notifications.js:559-585: pm → `openUserPM`, group → `openGroup`, reaction/
  /// mention → the reactor's/author's PM, call → PM or group).
  void _openEntry(NotificationEntry entry) {
    final controller = ref.read(nostrControllerProvider);
    final appState = ref.read(appStateProvider.notifier);
    final route = entry.route ?? '';
    final sender = entry.senderPubkey ?? '';
    final isPubkeyRoute = _isPubkey(route);
    switch (entry.type) {
      case 'group':
        if (route.isNotEmpty) appState.switchView(ChatView.group(route));
        break;
      case 'channel':
      case 'geohash':
        // A channel/geohash mention switches to that channel (the route is the
        // bare channel name; switchChannel auto-detects geohash).
        if (route.isNotEmpty) controller.switchChannel(route);
        break;
      case 'call':
        // Call routes carry a group id (group call) or a pubkey (1:1 call).
        if (isPubkeyRoute) {
          controller.startPM(route);
        } else if (route.isNotEmpty) {
          appState.switchView(ChatView.group(route));
        } else if (sender.isNotEmpty) {
          controller.startPM(sender);
        }
        break;
      case 'pm':
      case 'mention':
      case 'reaction':
      default:
        // These route to the sender's PM (the avatar pubkey).
        final target = sender.isNotEmpty
            ? sender
            : (isPubkeyRoute ? route : '');
        if (target.isNotEmpty) controller.startPM(target);
        break;
    }
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          // .modal-content (radius 24, glass border, shadow + glow + 1px ring),
          // max-width 500, width 90%.
          width: MediaQuery.of(context).size.width * 0.9,
          constraints: const BoxConstraints(maxWidth: 500, maxHeight: 640),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            border: Border.all(color: c.glassBorder),
            // `body.light-mode .modal-content { box-shadow: 0 8px 40px
            // rgba(0,0,0,0.12) }` — one soft shadow, no glow, no white ring in
            // light (styles-themes-responsive.css:1050-1052).
            boxShadow: c.isLight
                ? const [
                    BoxShadow(
                      color: Color(0x1F000000), // black @ 0.12
                      blurRadius: 40,
                      offset: Offset(0, 8),
                    ),
                  ]
                : [
                    const BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    BoxShadow(
                        color: c.primary.withValues(alpha: 0.1),
                        blurRadius: 20),
                    BoxShadow(
                        color: Colors.white.withValues(alpha: 0.05),
                        spreadRadius: 1),
                  ],
          ),
          child: Stack(
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // .modal-header: 22px UPPERCASE primary + ls1.5 + bottom rule.
                  // (padding 32 top/sides, 14 bottom, then a 1px glass divider.)
                  Container(
                    padding: const EdgeInsets.fromLTRB(32, 32, 32, 14),
                    decoration: BoxDecoration(
                      border:
                          Border(bottom: BorderSide(color: c.glassBorder)),
                    ),
                    child: Text(
                      'NOTIFICATIONS',
                      style: TextStyle(
                        color: c.primary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  // .notifications-mark-read-row (flex-end, padding 8/24/0).
                  if (_hasUnread)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _MarkReadBtn(onTap: _markAllRead),
                      ),
                    ),
                  // .notifications-modal-body (max-height 60vh, padding
                  // 12/24/24).
                  Flexible(
                    child: _rows.isEmpty
                        ? Padding(
                            // .notifications-empty: centered textDim 14,
                            // padding 40/20.
                            padding: const EdgeInsets.fromLTRB(20, 40, 20, 40),
                            child: Text(
                              'No notifications in the last 24 hours',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: c.textDim, fontSize: 14),
                            ),
                          )
                        : ListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                            itemCount: _rows.length,
                            itemBuilder: (ctx, i) => _NotificationRow(
                              entry: _rows[i].entry,
                              viewed: _rows[i].viewed,
                              isLast: i == _rows.length - 1,
                              onTap: () => _openEntry(_rows[i].entry),
                            ),
                          ),
                  ),
                ],
              ),
              // .modal-close chip.
              Positioned(
                top: 14,
                right: 14,
                child: _CloseChip(
                  onTap: () => Navigator.of(context).maybePop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A snapshotted notification row: the live [entry] plus its [viewed] state
/// frozen at open (then locally toggled by "Mark all read").
class _NotifRow {
  _NotifRow(this.entry, this.viewed);
  final NotificationEntry entry;
  bool viewed;
}

/// True when [s] is a bare 64-hex pubkey (drives the avatar + decorated author,
/// and PM routing).
bool _isPubkey(String s) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s);

/// `.notifications-mark-read-btn`: borderless primary 12px, underline on hover.
class _MarkReadBtn extends StatefulWidget {
  const _MarkReadBtn({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_MarkReadBtn> createState() => _MarkReadBtnState();
}

class _MarkReadBtnState extends State<_MarkReadBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            'Mark all read',
            style: TextStyle(
              color: c.primary,
              fontSize: 12,
              decoration:
                  _hover ? TextDecoration.underline : TextDecoration.none,
              decorationColor: c.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class _NotificationRow extends ConsumerWidget {
  const _NotificationRow({
    required this.entry,
    required this.viewed,
    required this.isLast,
    required this.onTap,
  });
  final NotificationEntry entry;
  final bool viewed;
  final bool isLast;
  final VoidCallback onTap;

  /// `Jun 23, 14:05` — `toLocaleString({month, day, hour, minute})`.
  String _formatTime(int ms) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${months[d.month - 1]} ${d.day}, $hh:$mm';
  }

  /// The footer context label (`.notification-item-context`) from the entry
  /// (notifications.js:519-533). The PWA keys off `channelInfo` with
  /// `in #<geohash>` / `in <groupName>` for channel + group sources, so PREFER
  /// the entry's carried [NotificationEntry.contextLabel] when present (the
  /// controller passes `in #<geohash>` for a channel mention / `in <GroupName>`
  /// for a group). Otherwise fall back to the type-derived label. Call bodies
  /// already encode "Missed video/audio call …", so a missed call needs none.
  String? _contextLabel() {
    final carried = entry.contextLabel;
    if (carried != null && carried.isNotEmpty) return carried;
    switch (entry.type) {
      case 'call':
        return entry.body.startsWith('Missed') ? null : 'Call';
      case 'pm':
        return 'PM';
      case 'reaction':
        return 'Reaction';
      case 'mention':
        return 'Mention';
      case 'group':
        // Fallback when no group name was carried on the entry.
        return 'Group';
      default:
        return null;
    }
  }

  /// Strips blockquoted (`>`-prefixed) lines and collapses whitespace, matching
  /// the PWA modal body (notifications.js:546-547) so only the new message text
  /// shows — not the quoted context a reply carries.
  String _displayBody() {
    final lines = entry.body
        .split('\n')
        .where((l) => !l.startsWith('>'))
        .join(' ');
    final collapsed = lines.replaceAll(RegExp(r'\s+'), ' ').trim();
    return collapsed.length > 200 ? collapsed.substring(0, 200) : collapsed;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // The avatar + decorated author render from the SENDER pubkey (the PWA modal
    // keys both off `n.senderPubkey || channelInfo.pubkey`, notifications.js:496)
    // — so a group message shows the sender's avatar + nym with `in <Group>` as
    // context, exactly like a PM/channel row. Fall back to the route only when no
    // sender pubkey was carried (older call entries).
    final sender = entry.senderPubkey ?? '';
    final route = entry.route ?? '';
    final pubkey = _isPubkey(sender)
        ? sender
        : (_isPubkey(route) ? route : '');
    final hasPubkey = pubkey.isNotEmpty;
    final label = _contextLabel();
    // Real profile picture for the sender avatar (Rule 4).
    final picture =
        hasPubkey ? ref.watch(usersProvider)[pubkey]?.profile?.picture : null;
    final body = _displayBody();

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            // .notification-item-unread: cyan@6% wash + 2px primary left rule.
            // (The wash hex is fixed `0,255,255` — NOT the theme primary.)
            color: viewed ? null : const Color.fromRGBO(0, 255, 255, 0.06),
            border: viewed
                ? (isLast
                    ? null
                    : Border(
                        bottom: BorderSide(
                            color: Colors.white.withValues(alpha: 0.04))))
                : Border(left: BorderSide(color: c.primary, width: 2)),
          ),
          // .notification-item-header: gap 6, align flex-start.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (hasPubkey) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: NymAvatar(seed: pubkey, size: 28, imageUrl: picture),
                ),
                const SizedBox(width: 6),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // .notification-item-author: `<base#suffix>` in primary, w600.
                    // The angle brackets are literal (`.nym-bracket`, inherits the
                    // primary author color).
                    _Author(entry: entry, pubkey: pubkey),
                    const SizedBox(height: 2),
                    // .notification-item-body: text 13, line-height 1.4, 2-line
                    // clamp. Routed through [InlineEmojiText] so a `:shortcode:`
                    // in the previewed message / reaction renders as its custom-
                    // emoji image instead of literal text.
                    InlineEmojiText(
                      text: body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(color: c.text, fontSize: 13, height: 1.4),
                    ),
                    const SizedBox(height: 2),
                    // .notification-item-footer: context label + time (both 11px dim).
                    Row(
                      children: [
                        if (label != null) ...[
                          Text(label,
                              style:
                                  TextStyle(color: c.textDim, fontSize: 11)),
                          const SizedBox(width: 6),
                        ],
                        Text(_formatTime(entry.ts),
                            style: TextStyle(color: c.textDim, fontSize: 11)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// `.notification-item-author` — the author wrapped in literal `<…>` brackets
/// (`.nym-bracket`, primary), with the decorated nym (base + dim `#suffix` +
/// badges) inside. For non-pubkey entries the bare title is bracketed.
class _Author extends StatelessWidget {
  const _Author({required this.entry, required this.pubkey});
  final NotificationEntry entry;

  /// The sender pubkey to decorate (empty → render the bare bracketed title).
  final String pubkey;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final bracket =
        TextStyle(color: c.primary, fontSize: 13, fontWeight: FontWeight.w600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('<', style: bracket),
        Flexible(
          child: pubkey.isNotEmpty
              ? CallNym(
                  pubkey: pubkey,
                  nym: entry.title,
                  baseColor: c.primary,
                  baseStyle: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                  badgeSize: 12,
                )
              : Text(
                  entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: c.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
        ),
        Text('>', style: bracket),
      ],
    );
  }
}

/// 32×32 circular glass close chip with a danger hover (`.modal-close`).
class _CloseChip extends StatefulWidget {
  const _CloseChip({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_CloseChip> createState() => _CloseChipState();
}

class _CloseChipState extends State<_CloseChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hover
                ? c.danger.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: _hover ? c.danger.withValues(alpha: 0.3) : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: _hover ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
