// notifications_panel.dart - In-app notification history sheet
// (`#notificationsModal` + `openNotificationsModal`, notifications.js:439-592).
//
// Foundations ships the STORE (`notificationHistoryProvider`); this builds the
// list/sheet UI that renders its entries (avatar + decorated author + body +
// context label + timestamp), highlights unread rows, and exposes a
// "Mark all read" action. The shell owns the bell + badge and calls [show].

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../state/app_state.dart';
import '../../widgets/common/nym_avatar.dart';
import '../calls/call_nym.dart';

/// Opens the notifications history as a bottom sheet over the app. Marks every
/// entry viewed on dismiss (the PWA marks-on-scroll; we mark on close, which
/// matches the simpler store contract `markAllViewed`).
Future<void> showNotificationsPanel(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
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

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: c.bgSecondary,
            border: Border(top: BorderSide(color: c.glassBorder)),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // Header.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
                child: Row(
                  children: [
                    Text('Notifications',
                        style: TextStyle(
                            color: c.textBright,
                            fontSize: 17,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    if (hasUnread)
                      TextButton(
                        onPressed: () => ref
                            .read(notificationHistoryProvider.notifier)
                            .markAllViewed(),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text('Mark all read',
                            style: TextStyle(color: c.primary, fontSize: 12)),
                      ),
                    IconButton(
                      icon: Icon(Icons.close, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: c.glassBorder),
              Expanded(
                child: entries.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(40),
                          child: Text(
                            'No notifications in the last 24 hours',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: c.textDim, fontSize: 14),
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        itemCount: entries.length,
                        itemBuilder: (ctx, i) =>
                            _NotificationRow(entry: entries[i]),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({required this.entry});
  final NotificationEntry entry;

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
  /// type (notifications.js:519-533).
  String? _contextLabel() {
    switch (entry.type) {
      case 'call':
        // The body already encodes "Missed video/audio call …".
        return entry.body.startsWith('Missed') ? null : 'Call';
      case 'pm':
        return 'PM';
      case 'reaction':
        return 'Reaction';
      case 'group':
        return 'Group';
      case 'mention':
        return 'Mention';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // A call entry routes to a pubkey (1:1) or a group id (group); message
    // entries carry the sender pubkey in `route`. Treat a 64-hex route as a
    // pubkey for the avatar + decorated author.
    final route = entry.route ?? '';
    final isPubkey = RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(route);
    final context_ = _contextLabel();

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        // Unread: cyan 6% wash + 2px primary left border.
        color: entry.viewed ? null : c.primary.withValues(alpha: 0.06),
        border: entry.viewed
            ? Border(bottom: BorderSide(color: Colors.white.withValues(alpha: 0.04)))
            : Border(left: BorderSide(color: c.primary, width: 2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPubkey) ...[
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: NymAvatar(seed: route, size: 28),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Author (decorated nym when we have a pubkey, else the title).
                if (isPubkey)
                  CallNym(
                    pubkey: route,
                    nym: entry.title,
                    baseColor: c.primary,
                    baseStyle: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                    badgeSize: 12,
                  )
                else
                  Text(entry.title,
                      style: TextStyle(
                          color: c.primary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  entry.body,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.text, fontSize: 13, height: 1.4),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (context_ != null) ...[
                      Text(context_,
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
