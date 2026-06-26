import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../../models/poll.dart';
import '../../models/settings.dart';
import '../../models/user.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../widgets/chat/message_row.dart' show formatTime, abbreviateNumber;
import '../../widgets/common/nym_avatar.dart';
import '../reactions/reactors_modal.dart';

/// An inline poll message (`displayPollMessage`, `polls.js:187-371`). Renders a
/// `.poll-container` (📊 Poll header + question + option rows with animated vote
/// bars, `NN%`, voted highlight, voter-avatar stacks, and an "N votes" footer)
/// under a compact author line. Tapping an option casts a vote
/// ([NostrController.votePoll]); tapping the footer opens the voters modal.
///
/// CSS source of truth: `styles-features.css:3992-4120`.
class PollCard extends ConsumerWidget {
  const PollCard({super.key, required this.poll, required this.settings});

  final Poll poll;
  final Settings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    final controller = ref.read(nostrControllerProvider);
    // Watch app state so a new vote re-tallies the bars live.
    ref.watch(appStateProvider);

    final selfPubkey = ref.watch(appStateProvider).selfPubkey;
    final hasVoted = poll.votes.containsKey(selfPubkey);
    final votedIndex = hasVoted ? poll.votes[selfPubkey] : null;
    final total = poll.totalVotes;

    final users = ref.watch(usersProvider);
    final authorPic = users[poll.pubkey]?.profile?.picture;
    final baseNym = stripPubkeySuffix(poll.nym.isEmpty ? 'nym' : poll.nym);
    final suffix = getPubkeySuffix(poll.pubkey);
    final timeStr = poll.createdAt > 0
        ? formatTime(
            DateTime.fromMillisecondsSinceEpoch(poll.createdAt * 1000),
            settings.timeFormat,
          )
        : '';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Compact author line: 18px avatar + <nym#suffix> + time.
          Padding(
            padding: const EdgeInsets.only(bottom: 4, left: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                NymAvatar(seed: poll.pubkey, size: 18, imageUrl: authorPic),
                const SizedBox(width: 4),
                Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: baseNym,
                      style: TextStyle(
                        color: c.secondary,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    if (suffix.isNotEmpty)
                      TextSpan(
                        text: '#$suffix',
                        style: TextStyle(
                          color: c.secondaryA(0.7),
                          fontSize: 13 * 0.9,
                          fontWeight: FontWeight.w100,
                        ),
                      ),
                  ]),
                ),
                if (timeStr.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Text(timeStr,
                      style: TextStyle(color: c.textDim, fontSize: 11)),
                ],
              ],
            ),
          ),
          // `.poll-container`.
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                // `body.light-mode .poll-container { background: rgba(0,0,0,0.03) }`
                // (styles-themes-responsive.css:1510-1513); dark white@0.04.
                color: c.isLight
                    ? const Color(0x08000000) // black @ 0.03
                    : Colors.white.withValues(alpha: 0.04),
                border: Border.all(color: c.glassBorder),
                borderRadius: NymRadius.rmd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // `.poll-header`.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      '📊 POLL',
                      style: TextStyle(
                        color: c.textDim,
                        fontSize: 11,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // `.poll-question`.
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      poll.question,
                      style: TextStyle(
                        color: c.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  // `.poll-options` (flex column, gap 8).
                  for (var i = 0; i < poll.options.length; i++) ...[
                    if (i > 0) const SizedBox(height: 8),
                    _PollOption(
                      poll: poll,
                      option: poll.options[i],
                      total: total,
                      selected: votedIndex == poll.options[i].index,
                      avatarFor: (pk) => users[pk]?.profile?.picture,
                      onTap: hasVoted
                          ? null
                          : () => controller.votePoll(
                              poll.id, poll.options[i].index),
                    ),
                  ],
                  // `.poll-footer` ("N vote(s)") → voters modal.
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _PollFooter(
                      total: total,
                      onTap: () => _showVoters(context, ref, users),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showVoters(
      BuildContext context, WidgetRef ref, Map<String, User> users) {
    final box = context.findRenderObject() as RenderBox?;
    final anchor = (box != null && box.hasSize)
        ? box.localToGlobal(Offset.zero) & box.size
        : Rect.zero;
    final reactors = <ReactorEntry>[
      for (final e in poll.votes.entries)
        ReactorEntry(
          pubkey: e.key,
          nym: stripPubkeySuffix(
              users[e.key]?.nym ?? getNymFromPubkey('anon', e.key)),
          suffix: getPubkeySuffix(e.key),
          imageUrl: users[e.key]?.profile?.picture,
          // Each voter's chosen option (polls.js showPollVotersModal renders the
          // selected option label per voter).
          subtitle: (e.value >= 0 && e.value < poll.options.length)
              ? poll.options[e.value].text
              : null,
        ),
    ];
    final total = poll.totalVotes;
    showReactorsModal(
      context,
      anchorRect: anchor,
      emoji: '📊',
      reactors: reactors,
      title: '$total vote${total == 1 ? '' : 's'}',
      // Tapping a voter opens a PM with them (polls.js click-to-open-PM).
      onTapReactor: (r) => ref.read(nostrControllerProvider).startPM(r.pubkey),
    );
  }
}

/// One `.poll-option` row: an absolutely-positioned gradient bar animating its
/// width to `pct%` over 400ms, the option text + right-aligned `NN%`, and a
/// voter-avatar stack (up to 8 + "+N"). Selected rows tint the border/bg primary.
class _PollOption extends StatelessWidget {
  const _PollOption({
    required this.poll,
    required this.option,
    required this.total,
    required this.selected,
    required this.avatarFor,
    required this.onTap,
  });

  final Poll poll;
  final PollOption option;
  final int total;
  final bool selected;
  final String? Function(String pubkey) avatarFor;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final count = poll.votesFor(option.index);
    final pct = total > 0 ? ((count / total) * 100).round() : 0;
    final voters =
        poll.votes.entries.where((e) => e.value == option.index).toList();

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? Colors.white.withValues(alpha: 0.06) : null,
          border: Border.all(color: selected ? c.primary : c.glassBorder),
          borderRadius: NymRadius.rsm,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // `.poll-option-bar`: full-height gradient fill whose WIDTH animates
            // to `pct%` over 400ms (`transition: width 0.4s ease`).
            Positioned.fill(
              child: AnimatedFractionallySizedBox(
                duration: const Duration(milliseconds: 400),
                curve: Curves.ease,
                alignment: Alignment.centerLeft,
                widthFactor: (pct / 100.0).clamp(0.0, 1.0),
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: NymRadius.rsm,
                    // `body.light-mode .poll-option-bar` flips to black@.06→.02
                    // and the selected bar to a blue rgb(0,100,200) tint
                    // (styles-themes-responsive.css:1519-1525). Dark base is
                    // white@.06→.02 / primary@.15→.05 (styles-features.css:4044).
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: selected
                          ? (c.isLight
                              ? const [Color(0x1F0064C8), Color(0x0A0064C8)]
                              : [c.primaryA(0.15), c.primaryA(0.05)])
                          : (c.isLight
                              ? const [Color(0x0F000000), Color(0x05000000)]
                              : [
                                  Colors.white.withValues(alpha: 0.06),
                                  Colors.white.withValues(alpha: 0.02),
                                ]),
                    ),
                  ),
                ),
              ),
            ),
            // `.poll-option-content` + `.poll-voters`.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          option.text,
                          style: TextStyle(color: c.text, fontSize: 13),
                        ),
                      ),
                      if (total > 0)
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 35),
                          child: Text(
                            '$pct%',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: c.textDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (voters.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _VoterStack(
                        voters: voters.map((e) => e.key).toList(),
                        avatarFor: avatarFor,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `.poll-voters`: up to 8 × 20px round avatars (1px glass border) + "+N".
class _VoterStack extends StatelessWidget {
  const _VoterStack({required this.voters, required this.avatarFor});
  final List<String> voters;
  final String? Function(String pubkey) avatarFor;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final visible = voters.take(8).toList();
    final extra = voters.length - visible.length;
    return Wrap(
      spacing: 2,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final pk in visible)
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: c.glassBorder),
            ),
            child: NymAvatar(seed: pk, size: 20, imageUrl: avatarFor(pk)),
          ),
        if (extra > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '+$extra',
              style: TextStyle(color: c.textDim, fontSize: 10),
            ),
          ),
      ],
    );
  }
}

/// `.poll-footer`: "N vote(s)" text-dim 11px, tappable (voters modal).
class _PollFooter extends StatelessWidget {
  const _PollFooter({required this.total, required this.onTap});
  final int total;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final label =
        '${abbreviateNumber(total)} vote${total == 1 ? '' : 's'}';
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: TextStyle(color: c.textDim, fontSize: 11),
      ),
    );
  }
}
