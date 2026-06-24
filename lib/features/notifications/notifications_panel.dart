// notifications_panel.dart - In-app notification history modal
// (`#notificationsModal` + `openNotificationsModal`, notifications.js:439-592).
//
// Foundations ships the STORE (`notificationHistoryProvider`); this builds the
// modal UI that renders its entries (avatar + decorated author wrapped in
// `<…>` brackets + body + context label + timestamp), highlights unread rows
// (cyan wash + primary left rule), and exposes a "Mark all read" action. The
// shell owns the bell + badge and calls [showNotificationsPanel].
//
// Rendered as a centered `.modal` (showDialog) with shared modal chrome: 22px
// UPPERCASE primary header + bottom rule, 32px circular glass close chip.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../calls/call_nym.dart';

/// Opens the notifications history as a centered modal (the PWA renders it as a
/// `.modal` overlay). Marks every entry viewed on dismiss (the PWA marks-on-
/// scroll; we mark on close, which matches the simpler store contract
/// `markAllViewed`).
Future<void> showNotificationsPanel(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xB3000000), // .modal overlay rgba(0,0,0,0.7)
    builder: (_) => const NotificationsPanel(),
  );
}

class NotificationsPanel extends ConsumerWidget {
  const NotificationsPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final store = ref.watch(notificationHistoryProvider);
    // Newest-first; the store already trims to 24h.
    final entries = store.entries;
    final hasUnread = store.unread > 0;

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
            boxShadow: [
              const BoxShadow(
                color: Color(0x80000000),
                blurRadius: 32,
                offset: Offset(0, 8),
              ),
              BoxShadow(color: c.primary.withValues(alpha: 0.1), blurRadius: 20),
              BoxShadow(
                  color: Colors.white.withValues(alpha: 0.05), spreadRadius: 1),
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
                  if (hasUnread)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _MarkReadBtn(
                          onTap: () => ref
                              .read(notificationHistoryProvider.notifier)
                              .markAllViewed(),
                        ),
                      ),
                    ),
                  // .notifications-modal-body (max-height 60vh, padding
                  // 12/24/24).
                  Flexible(
                    child: entries.isEmpty
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
                            itemCount: entries.length,
                            itemBuilder: (ctx, i) => _NotificationRow(
                              entry: entries[i],
                              isLast: i == entries.length - 1,
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
  const _NotificationRow({required this.entry, required this.isLast});
  final NotificationEntry entry;
  final bool isLast;

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // A call entry routes to a pubkey (1:1) or a group id (group); message
    // entries carry the sender pubkey in `route`. Treat a 64-hex route as a
    // pubkey for the avatar + decorated author.
    final route = entry.route ?? '';
    final isPubkey = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(route);
    final label = _contextLabel();
    // Real profile picture for the sender avatar (Rule 4).
    final picture =
        isPubkey ? ref.watch(usersProvider)[route]?.profile?.picture : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // .notification-item-unread: cyan@6% wash + 2px primary left rule.
        // (The wash hex is fixed `0,255,255` — NOT the theme primary.)
        color: entry.viewed
            ? null
            : const Color.fromRGBO(0, 255, 255, 0.06),
        border: entry.viewed
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
          if (isPubkey) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: NymAvatar(seed: route, size: 28, imageUrl: picture),
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
                _Author(entry: entry, isPubkey: isPubkey),
                const SizedBox(height: 2),
                // .notification-item-body: text 13, line-height 1.4, 2-line clamp.
                Text(
                  entry.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 2),
                // .notification-item-footer: context label + time (both 11px dim).
                Row(
                  children: [
                    if (label != null) ...[
                      Text(label,
                          style: TextStyle(color: c.textDim, fontSize: 11)),
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
    );
  }
}

/// `.notification-item-author` — the author wrapped in literal `<…>` brackets
/// (`.nym-bracket`, primary), with the decorated nym (base + dim `#suffix` +
/// badges) inside. For non-pubkey entries the bare title is bracketed.
class _Author extends StatelessWidget {
  const _Author({required this.entry, required this.isPubkey});
  final NotificationEntry entry;
  final bool isPubkey;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final route = entry.route ?? '';
    final bracket =
        TextStyle(color: c.primary, fontSize: 13, fontWeight: FontWeight.w600);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('<', style: bracket),
        Flexible(
          child: isPubkey
              ? CallNym(
                  pubkey: route,
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
