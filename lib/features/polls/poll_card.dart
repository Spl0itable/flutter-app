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
import '../../state/settings_provider.dart';
import '../../widgets/chat/message_row.dart' show formatTime, abbreviateNumber;
import '../../widgets/common/nym_avatar.dart';
import '../../widgets/context_menu/context_menu_actions.dart';
import '../../widgets/context_menu/context_menu_panel.dart';
import '../reactions/reactors_modal.dart';
import '../translate/translate_languages.dart';
import '../translate/translate_service.dart';

/// An inline poll message (`displayPollMessage`, `polls.js:187-371`). Renders a
/// `.poll-container` (📊 Poll header + question + option rows with animated vote
/// bars, `NN%`, voted highlight, voter-avatar stacks, and an "N votes" footer)
/// under a compact author line. Tapping an option casts a vote
/// ([NostrController.votePoll]); tapping the footer opens the voters modal.
///
/// CSS source of truth: `styles-features.css:3992-4120`.
class PollCard extends ConsumerStatefulWidget {
  const PollCard({super.key, required this.poll, required this.settings});

  final Poll poll;
  final Settings settings;

  @override
  ConsumerState<PollCard> createState() => _PollCardState();
}

class _PollCardState extends ConsumerState<PollCard> {
  // Inline-translation state (mirrors `MessageRow._showTranslation` /
  // `_translateLangOverride`, message_row.dart:179-180): rendered below the
  // `.poll-container` once the user picks Translate from the author context
  // menu (polls.js author click → showContextMenu Translate → `translatePoll`).
  bool _showTranslation = false;
  String? _translateLangOverride;

  @override
  Widget build(BuildContext context) {
    final poll = widget.poll;
    final settings = widget.settings;
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
                // `.author-clickable` (polls.js): avatar + nym → open the same
                // user context menu a normal message author does, carrying the
                // poll question as `[Poll] …` content and the poll id.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openAuthorMenu(context, selfPubkey),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      NymAvatar(
                          seed: poll.pubkey, size: 18, imageUrl: authorPic),
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
                    ],
                  ),
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
          // Inline poll translation (`translatePoll`, translate.js:361-406):
          // a `.message-translation` block under the poll rendering the
          // translated question + each option, constrained to the poll's width.
          if (_showTranslation)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _PollTranslation(
                key: ValueKey(_translateLangOverride ?? ''),
                poll: poll,
                targetLang: _translateLangOverride,
              ),
            ),
        ],
      ),
    );
  }

  /// `.author-clickable` click → the user context menu, mirroring a normal
  /// message author (polls.js `displayPollMessage`: `showContextMenu(e,
  /// displayAuthor, pubkey, '[Poll] '+question, pollId)`). The panel re-derives
  /// friend/block/group-role flags itself (context_menu_panel.dart:113), so we
  /// only supply identity + the poll body/id. The menu's Translate action then
  /// renders the inline poll translation via [onTranslateInline].
  void _openAuthorMenu(BuildContext context, String selfPubkey) {
    final poll = widget.poll;
    final isBot = ref.read(nostrControllerProvider).isVerifiedBot(poll.pubkey);
    ContextMenuPanel.show(
      context,
      target: CtxTarget(
        pubkey: poll.pubkey,
        nym: stripPubkeySuffix(poll.nym.isEmpty ? 'nym' : poll.nym),
        isSelf: poll.pubkey == selfPubkey,
        content: '[Poll] ${poll.question}',
        messageId: poll.id,
        isBot: isBot,
      ),
      onTranslateInline: (lang) => setState(() {
        _translateLangOverride = lang;
        _showTranslation = true;
      }),
    );
  }

  void _showVoters(
      BuildContext context, WidgetRef ref, Map<String, User> users) {
    final poll = widget.poll;
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

/// The inline `.message-translation` block for a poll (`translatePoll`,
/// translate.js:361-406). Translates the segment list `[question, …options]`
/// (each via [TranslateService.translate], mirroring `_translatePreservingMentions`)
/// and renders the translated question (`.poll-translation-question`, bold) over
/// `• option` lines (`.poll-translation-option`, 0.95em opacity 0.9) plus the
/// `source → target` label. Container styling matches [MessageTranslation]
/// (`.message-translation`, styles-features.css:4310-4320).
class _PollTranslation extends ConsumerStatefulWidget {
  const _PollTranslation({super.key, required this.poll, this.targetLang});

  final Poll poll;

  /// Override target language; defaults to `settings.translateLanguage`.
  final String? targetLang;

  @override
  ConsumerState<_PollTranslation> createState() => _PollTranslationState();
}

class _PollTranslationState extends ConsumerState<_PollTranslation> {
  final TranslateService _service = TranslateService();
  late final List<String> _segments;
  late final Future<List<TranslationResult>> _future;

  String get _target =>
      widget.targetLang ?? ref.read(settingsProvider).translateLanguage;

  @override
  void initState() {
    super.initState();
    // `[poll.question, ...poll.options.map(o => o.text)]` (translate.js:380).
    _segments = [
      widget.poll.question,
      for (final o in widget.poll.options) o.text,
    ];
    final target = _target.isEmpty ? 'en' : _target;
    _future = Future.wait(
      _segments.map((s) => _service.translate(s, target)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        // `.message-translation` — bg white@0.04, left primary rule, right-only
        // radius (styles-features.css:4310-4320).
        color: Colors.white.withValues(alpha: 0.04),
        border: Border(left: BorderSide(color: c.primary, width: 3)),
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(NymRadius.xs),
          bottomRight: Radius.circular(NymRadius.xs),
        ),
      ),
      child: FutureBuilder<List<TranslationResult>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            // `.translation-loading`: static italic dim@0.6 (no pulse, matching
            // the inline message translation, styles-features.css:4333).
            return Text(
              'Translating...',
              style: TextStyle(
                color: c.textDim.withValues(alpha: 0.6),
                fontStyle: FontStyle.italic,
                fontSize: 13,
              ),
            );
          }
          if (snap.hasError) {
            return Text(
              'Translation failed',
              style: TextStyle(color: c.danger, fontSize: 12),
            );
          }
          final results = snap.data!;
          final translated = [
            for (final r in results) r.translatedText,
          ];
          // `allNoop`: every segment came back blank or unchanged
          // (translate.js:387).
          final allNoop = () {
            for (var i = 0; i < _segments.length; i++) {
              final t = (i < translated.length ? translated[i] : '').trim();
              if (t.isNotEmpty && t != _segments[i].trim()) return false;
            }
            return true;
          }();
          if (allNoop) {
            return Text.rich(
              TextSpan(children: [
                const TextSpan(text: '🌐 '),
                TextSpan(
                  text:
                      'Already in ${languageName(_target)} (nothing to translate)',
                  style: TextStyle(color: c.danger, fontSize: 13 * 0.85),
                ),
              ]),
            );
          }
          // First non-`auto` detected language wins (translate.js:385).
          var detected = 'auto';
          for (final r in results) {
            if (r.detectedLanguage.isNotEmpty &&
                r.detectedLanguage != 'auto') {
              detected = r.detectedLanguage;
              break;
            }
          }
          final showLang = detected != 'auto' && detected != _target;
          final question = translated.isNotEmpty && translated[0].isNotEmpty
              ? translated[0]
              : widget.poll.question;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // `🌐` + `.poll-translation-question` (bold, margin-bottom 4).
              Text.rich(
                TextSpan(
                  style:
                      TextStyle(color: c.textDim, fontSize: 13, height: 1.4),
                  children: [
                    const TextSpan(text: '🌐 '),
                    TextSpan(
                      text: question,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // `.poll-translation-option` — "• {translated}" per option.
              for (var i = 0; i < widget.poll.options.length; i++)
                Text(
                  '• ${(i + 1 < translated.length && translated[i + 1].isNotEmpty) ? translated[i + 1] : widget.poll.options[i].text}',
                  style: TextStyle(
                    color: c.textDim.withValues(alpha: 0.9),
                    fontSize: 13 * 0.95,
                    height: 1.4,
                  ),
                ),
              if (showLang)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${languageName(detected)} → ${languageName(_target)}',
                    style: TextStyle(
                      color: c.textDim.withValues(alpha: 0.7),
                      fontSize: 13 * 0.8,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
