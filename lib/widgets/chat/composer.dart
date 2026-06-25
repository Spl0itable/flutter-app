import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../core/utils/nym_utils.dart';
import '../nym_icons.dart';
import '../../features/autocomplete/autocomplete_dropdown.dart';
import '../../features/autocomplete/autocomplete_queries.dart';
import '../../features/autocomplete/autocomplete_triggers.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/commands/command_handler.dart';
import '../../features/commands/command_palette.dart';
import '../../features/commands/command_registry.dart';
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/emoji_data.dart';
import '../../features/emoji/emoji_picker.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/polls/poll_create_modal.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_languages.dart';
import '../../features/translate/translate_service.dart';
import '../../features/zaps/zap_modal.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../context_menu/interaction_hooks.dart';

/// The message composer (`.input-container` + `.message-input` + `.input-buttons`,
/// docs/specs/02 §5.5). A multi-line input with a toolbar of image/file/emoji/GIF
/// icon buttons and a SEND button wired to a local echo. On mobile the toolbar
/// stacks full-width below the input. (docs/specs/02 §1.2)
class Composer extends ConsumerStatefulWidget {
  const Composer({super.key, required this.compact});

  /// Mobile/tablet: stack toolbar below the input (column layout).
  final bool compact;

  @override
  ConsumerState<Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<Composer> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  // Inline composer popovers (`#emojiPicker` / `#gifPicker`). Only one open at
  // a time, anchored above the toolbar button like the PWA's inline popups.
  final _emojiPortal = OverlayPortalController();
  final _gifPortal = OverlayPortalController();
  final _emojiAnchor = LayerLink();
  final _gifAnchor = LayerLink();

  // Lazily-loaded prefs + stores (only touched once a picker is opened).
  SharedPreferences? _prefs;
  List<String> _recents = const [];

  // LIVE NIP-30 custom emoji (kind-30030 packs + kind-10030 list + inbound
  // `emoji` tags). Synced from [liveCustomEmojiProvider] on every build so the
  // emoji picker AND the `:` autocomplete surface user/relay packs — not just
  // the static `loadCustomEmojiState` cache. (The live notifier itself hydrates
  // from that cache, so this is a strict superset.)
  CustomEmojiState _customEmojis = CustomEmojiState.empty;

  // --- Quote-reply / edit preview chips (F1/F2) ----------------------------
  // The PWA defers the quote/edit until SEND: a colored chip sits above the
  // input while the user's typed text stays clean (messages.js setQuoteReply /
  // startEditMessage). `_pendingQuote` carries the author + stripped text;
  // `_pendingEdit` carries the message id + original content.
  ({String author, String text})? _pendingQuote;
  PendingEdit? _pendingEdit;

  // --- In-composer translate (F7) ------------------------------------------
  // A 26×26 translate button overlaid bottom-right of the input opens a 230px
  // language dropdown; choosing a language translates the typed draft in place
  // (`#translateInputBtn` / `.translate-input-dropdown`, ui-context.js).
  final _translatePortal = OverlayPortalController();
  final _translateAnchor = LayerLink();
  final _translateSearchController = TextEditingController();
  String _translateQuery = '';
  bool _translating = false;

  /// Translate-dropdown favorites (`nym_translate_favorites`), pinned to the top
  /// of the language list. Loaded once prefs resolve (translate.js:93-99).
  List<String> _translateFavorites = const [];

  /// The favorites-pinned language order, snapshotted when the dropdown opens.
  /// The PWA only re-pins on the next open ("the list order updates the next
  /// time the dropdown opens", translate.js:563-571) — toggling a star mid-open
  /// flips its fill in place but does NOT reorder until reopen.
  List<MapEntry<String, String>> _translateLangOrder = const [];

  /// Whether the draft is tall enough to float into the `.composer-popout` box
  /// (PWA expands when content exceeds ~1.5 lines, ui-context.js:1738).
  bool _popout = false;

  /// MIME of the in-flight upload, so the progress label reads
  /// "Uploading video…" vs "…image…" (F6).
  String? _uploadMime;

  // --- Autocomplete / command palette state --------------------------------
  // The active trigger token at the caret + its rendered content. Mirrors the
  // PWA's single-active-dropdown model (only one of @/#/:/\\/`/` is open).
  final _acAnchor = LayerLink();
  final _acPortal = OverlayPortalController();
  TriggerMatch _trigger = const TriggerMatch.none();
  AutocompleteView? _acView;
  List<PaletteRow> _paletteRows = const [];
  // The public `?` Nymbot command palette rows (showBotCommandPalette). Same
  // `#commandPalette` surface as `/`, populated from the real bot catalogue.
  List<BotPaletteCommand> _botRows = const [];
  int _selectedIndex = 0;

  bool get _paletteActive => _trigger.kind == TriggerKind.command;
  bool get _botPaletteActive => _trigger.kind == TriggerKind.botCommand;
  bool get _acActive => _acView != null && !_acView!.isEmpty;
  bool get _overlayActive => _paletteActive
      ? _paletteRows.isNotEmpty
      : (_botPaletteActive ? _botRows.isNotEmpty : _acActive);

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _controller.dispose();
    _focus.dispose();
    _translateSearchController.dispose();
    super.dispose();
  }

  /// Applies a mention/quote request from the context menu (ui-context.js
  /// `insertMention` / `setQuoteReply`). Mentions splice at the caret; quotes
  /// set the [_pendingQuote] chip (deferred to send) rather than dumping
  /// `> @author:` markdown into the field.
  void _applyComposerAction(ComposerAction action) {
    switch (action) {
      case MentionAction(:final fullNym):
        final existing = _controller.text;
        final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
        final insert = '${needsSpace ? ' ' : ''}@$fullNym ';
        _controller.text = existing + insert;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      case QuoteAction(:final fullNym, :final content):
        // Set the quote chip; the input text stays clean (messages.js:1816).
        _pendingQuote = (author: fullNym, text: _strippedQuoteText(content));
    }
    _focus.requestFocus();
    setState(() {});
  }

  /// Strips nested `>` quote lines (keep only the top level), collapses blank
  /// runs, and trims — the `setQuoteReply` pre-processing (messages.js:1817).
  static String _strippedQuoteText(String text) {
    final kept = <String>[];
    for (final line in text.split('\n')) {
      var depth = 0;
      var tmp = line;
      while (tmp.startsWith('>')) {
        depth++;
        tmp = tmp.substring(1).trimLeft();
      }
      if (depth < 1) kept.add(line);
    }
    return kept
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  /// The chip's cleaned preview text: strip HTML/markdown punctuation, cap 120
  /// (`cleanText` in setQuoteReply, messages.js:1845-1846).
  static String _quotePreviewText(String text) {
    final clean = text
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll(RegExp(r'[*_~`>#]'), '');
    return clean.length > 120 ? '${clean.substring(0, 120)}...' : clean;
  }

  void _clearQuote() {
    if (_pendingQuote == null) return;
    setState(() => _pendingQuote = null);
  }

  /// Enters inline-edit mode from a [pendingEditProvider] request: seed the
  /// input with the original content, drop any pending quote, show the amber
  /// edit chip, focus (startEditMessage, messages.js:1861).
  void _applyEdit(PendingEdit edit) {
    setState(() {
      _pendingEdit = edit;
      _pendingQuote = null;
    });
    _controller.text = edit.content;
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    _focus.requestFocus();
    _onInputChanged();
  }

  /// Cancels an in-progress edit and empties the input (cancelEditMessage,
  /// messages.js:1912).
  void _cancelEdit() {
    if (_pendingEdit == null) return;
    setState(() => _pendingEdit = null);
    _controller.clear();
    _onInputChanged();
  }

  @override
  void initState() {
    super.initState();
    // `.message-input:focus` lifts the fill + paints a 3px focus ring, so
    // rebuild on focus change to swap those in/out.
    _focus.addListener(_onFocusChanged);
    // Register the system-message sink + the modal/effect hooks so slash
    // commands that open a UI surface (poll, zap, PM, group create/admin)
    // actually fire instead of silently no-opping.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nostrControllerProvider).setCommandHooks(
            onSystemMessage: _onSystemMessage,
            hooks: _buildCommandHooks(),
          );
    });
  }

  /// Builds the modal/effect hooks for slash commands whose surface lives in
  /// the UI layer. Mirrors the PWA's `cmd*` handlers (commands.js) that open
  /// these surfaces; registered once with the dispatcher via [setCommandHooks].
  CommandHooks _buildCommandHooks() {
    final controller = ref.read(nostrControllerProvider);
    return CommandHooks(
      // `/poll` → the poll editor (`cmdPoll` → #pollModal).
      openPoll: () {
        if (mounted) PollCreateModal.open(context);
      },
      // `/pm @nym` → open/create the thread (target resolved by the dispatcher).
      openPm: (pubkey, nym) => controller.startPM(pubkey, nym: nym),
      // `/zap @nym` → resolve the LN address, then the zap modal (`cmdZap` →
      // showZapModal), mirroring the context-menu zap path.
      openZap: (pubkey, nym) async {
        final lnAddr =
            ref.read(usersProvider)[pubkey]?.profile?.lightningAddress;
        if (lnAddr == null || lnAddr.isEmpty) {
          _onSystemMessage(
              '@${stripPubkeySuffix(nym)} cannot receive zaps (no lightning address set)');
          return;
        }
        if (!mounted) return;
        await ZapModal.show(
          context,
          recipientPubkey: pubkey,
          recipientNym: nym,
          lightningAddress: lnAddr,
        );
      },
      // `/group @a @b [name]` → create the group (`cmdGroup` → createGroup).
      createGroup: (members, name) {
        if (members.isEmpty) {
          _onSystemMessage('Usage: /group @nym1 @nym2 [group name]');
          return;
        }
        unawaited(controller.createGroup(name, members));
      },
      // `/addmember @nym` (and `/invite @nym` in a group) → add to this group.
      addMember: _addMemberToCurrentGroup,
      invite: _addMemberToCurrentGroup,
      // `/groupinfo` → list owner / mods / member count (`cmdGroupInfo`).
      groupInfo: _showGroupInfo,
      // Group moderation (groups.js `cmd*`): the dispatcher resolves the target,
      // we act on the current group.
      kick: (pubkey) =>
          _withCurrentGroup((gid) => controller.kickFromGroup(gid, pubkey)),
      ban: (pubkey) =>
          _withCurrentGroup((gid) => controller.banFromGroup(gid, pubkey)),
      addMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.promoteModerator(gid, pubkey)),
      removeMod: (pubkey) =>
          _withCurrentGroup((gid) => controller.revokeModerator(gid, pubkey)),
      transferOwner: (pubkey) =>
          _withCurrentGroup((gid) => controller.transferOwner(gid, pubkey)),
    );
  }

  /// Runs [action] against the current group id when the active view is a group.
  void _withCurrentGroup(Future<void> Function(String groupId) action) {
    final view = ref.read(currentViewProvider);
    if (view.kind == ViewKind.group) unawaited(action(view.id));
  }

  /// Resolves [arg] and adds them to the current group (`/addmember`/`/invite`).
  void _addMemberToCurrentGroup(String arg) {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) {
      _onSystemMessage('You must be in a group to add members.');
      return;
    }
    final target = resolveTarget(arg, ref.read(usersProvider));
    if (target == null) {
      _onSystemMessage('User ${arg.trim()} not found');
      return;
    }
    unawaited(
        ref.read(nostrControllerProvider).addGroupMembers(view.id, [target.pubkey]));
  }

  /// Emits a `/groupinfo` summary (owner, mods, member count) as a system line.
  void _showGroupInfo() {
    final view = ref.read(currentViewProvider);
    if (view.kind != ViewKind.group) return;
    final group = ref.read(appStateProvider.notifier).groupById(view.id);
    if (group == null) return;
    final users = ref.read(usersProvider);
    String nymOf(String pk) {
      final u = users[pk];
      return u != null
          ? stripPubkeySuffix(u.nym)
          : 'nym#${pk.substring(pk.length - 4)}';
    }

    final owner =
        group.createdBy != null ? nymOf(group.createdBy!) : 'unknown';
    final lines = <String>[
      'Group: ${group.name.isEmpty ? '(unnamed)' : group.name}',
      'Owner: $owner',
      if (group.mods.isNotEmpty) 'Mods: ${group.mods.map(nymOf).join(', ')}',
      'Members: ${group.members.length}',
    ];
    _onSystemMessage(lines.join('\n'));
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onSystemMessage(String text) {
    if (!mounted) return;
    // Render an in-list system pill (PWA `addSystemMessage`) AND surface a
    // transient SnackBar so command feedback is visible even when scrolled away.
    ref.read(appStateProvider.notifier).addSystemMessage(text);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  /// Resolve prefs once, then hydrate recents + translate favorites. Custom
  /// emoji come from the LIVE [liveCustomEmojiProvider] (synced in `build`).
  Future<SharedPreferences> _ensurePrefs() async {
    if (_prefs != null) return _prefs!;
    final prefs = await ref.read(emojiPrefsProvider.future);
    _prefs = prefs;
    _recents = EmojiRecentsStore(prefs).load();
    _translateFavorites = _loadTranslateFavorites(prefs);
    return prefs;
  }

  /// Read the persisted translate favorites (`nym_translate_favorites`).
  static List<String> _loadTranslateFavorites(SharedPreferences prefs) {
    final raw = prefs.getString(kTranslateFavoritesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) return decoded.whereType<String>().toList();
    } catch (_) {}
    return const [];
  }

  /// Toggle [code] in the favorites list and persist (translate.js:102-108):
  /// append when absent, remove when present.
  void _toggleTranslateFavorite(String code) {
    final next = [..._translateFavorites];
    if (!next.remove(code)) next.add(code);
    setState(() => _translateFavorites = next);
    _prefs?.setString(kTranslateFavoritesKey, jsonEncode(next));
  }

  /// Insert text at the current selection (mirrors PWA `insertEmoji`/`insertGif`
  /// which splice at the caret), keeping focus in the input.
  void _insertAtCaret(String insert) {
    final sel = _controller.selection;
    final text = _controller.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final next = text.replaceRange(start, end, insert);
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
    setState(() {});
    _focus.requestFocus();
  }

  Future<void> _toggleEmojiPicker() async {
    if (_emojiPortal.isShowing) {
      _emojiPortal.hide();
      return;
    }
    _gifPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    setState(() {});
    _emojiPortal.show();
  }

  Future<void> _toggleGifPicker() async {
    if (_gifPortal.isShowing) {
      _gifPortal.hide();
      return;
    }
    _emojiPortal.hide();
    await _ensurePrefs();
    if (!mounted) return;
    setState(() {});
    _gifPortal.show();
  }

  /// Emoji chosen: insert (unicode char or `:shortcode:`) and bump recents.
  Future<void> _onEmojiSelected(String emoji) async {
    _insertAtCaret(emoji);
    _emojiPortal.hide();
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  void _onGifSelected(String url) {
    // PWA appends the GIF URL; the formatter renders it as media.
    _insertAtCaret(url);
    _gifPortal.hide();
  }

  // --- Autocomplete driving ------------------------------------------------

  /// Recomputes the active trigger + dropdown contents on every input change
  /// (mirrors handleInputChange + refresh*IfOpen). Re-queries as the user types.
  void _onInputChanged() {
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    final trigger = detectTrigger(_controller.text, caret: caret);
    _trigger = trigger;
    _selectedIndex = 0;

    // `.composer-popout`: float the input into an elevated box once the draft
    // exceeds ~1.5 lines (ui-context.js:1738). Approximate "extent" by newline
    // count + a rough wrap estimate so we don't need a layout pass.
    _popout = _estimatedLineCount() > 1;

    if (trigger.kind == TriggerKind.command) {
      _paletteRows = buildPaletteRows(trigger.query);
      _botRows = const [];
      _acView = null;
    } else if (trigger.kind == TriggerKind.botCommand) {
      // Public `?` Nymbot palette, filtered by `cmd.startsWith(input)`.
      _botRows = buildBotPaletteRows(trigger.query);
      _paletteRows = const [];
      _acView = null;
    } else if (trigger.kind != TriggerKind.none) {
      _paletteRows = const [];
      _botRows = const [];
      _acView = _buildAutocompleteView(trigger);
    } else {
      _paletteRows = const [];
      _botRows = const [];
      _acView = null;
    }

    if (_overlayActive) {
      if (!_acPortal.isShowing) _acPortal.show();
    } else {
      if (_acPortal.isShowing) _acPortal.hide();
    }
    setState(() {});
  }

  /// Cheap line-count estimate for the popout threshold: explicit newlines plus
  /// a per-line wrap estimate (~36 chars/line is a conservative composer width).
  int _estimatedLineCount() {
    final text = _controller.text;
    if (text.isEmpty) return 0;
    var lines = 0;
    for (final line in text.split('\n')) {
      lines += 1 + (line.length ~/ 36);
    }
    return lines;
  }

  AutocompleteView? _buildAutocompleteView(TriggerMatch trigger) {
    final state = ref.read(appStateProvider);
    final view = state.view;
    final currentKey =
        view.kind == ViewKind.channel ? view.id.toLowerCase() : '';

    switch (trigger.kind) {
      case TriggerKind.mention:
        // Priority pubkeys: the current PM peer / group members.
        Set<String>? priority;
        if (view.kind == ViewKind.pm) {
          priority = {view.id};
        } else if (view.kind == ViewKind.group) {
          final g = state.groups.where((g) => g.id == view.id);
          if (g.isNotEmpty) {
            priority =
                g.first.members.where((p) => p != state.selfPubkey).toSet();
          }
        }
        final results = queryMentions(
          users: state.users,
          search: trigger.query,
          currentChannelKey: currentKey,
          priority: priority,
        );
        return AutocompleteView.mentions(results);
      case TriggerKind.channel:
        final counts = <String, int>{};
        state.messages.forEach((key, msgs) {
          if (key.startsWith('#')) counts[key.substring(1)] = msgs.length;
        });
        final results = queryChannels(
          search: trigger.query,
          channels: state.channels,
          messageChannelCounts: counts,
          currentKey: currentKey,
        );
        return AutocompleteView.channels(results);
      case TriggerKind.emoji:
        final results = queryEmoji(
          search: trigger.query,
          recents: _recents,
          custom: _customEmojis,
        );
        return AutocompleteView.emoji(results);
      case TriggerKind.kaomoji:
        final sections = queryKaomoji(search: trigger.query);
        return AutocompleteView.kaomoji(sections);
      default:
        return null;
    }
  }

  void _hideOverlay() {
    _trigger = const TriggerMatch.none();
    _acView = null;
    _paletteRows = const [];
    _botRows = const [];
    if (_acPortal.isShowing) _acPortal.hide();
    setState(() {});
  }

  /// Replaces the trigger token (from [triggerIndex] to the caret) with [insert]
  /// and moves the caret to the end of the inserted text. Mirrors the splice in
  /// selectAutocomplete / insertChannelReference / selectSpecificEmojiAutocomplete.
  void _replaceTriggerToken(String insert) {
    final sel = _controller.selection;
    final caret = sel.isValid ? sel.start : _controller.text.length;
    final start = _trigger.triggerIndex;
    if (start < 0) return;
    final text = _controller.text;
    final next = text.replaceRange(start, caret, insert);
    final offset = start + insert.length;
    _controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: offset),
    );
    _hideOverlay();
    _focus.requestFocus();
    // Re-evaluate (the inserted trailing space closes the token).
    _onInputChanged();
  }

  void _completeCommand(CommandSpec spec) {
    // selectCommand inserts `"<command> "` then hides the palette.
    _controller.value = TextEditingValue(
      text: '${spec.name} ',
      selection: TextSelection.collapsed(offset: spec.name.length + 1),
    );
    _hideOverlay();
    _focus.requestFocus();
  }

  void _completeBotCommand(BotPaletteCommand cmd) {
    // selectCommand inserts `"?<name> "` (cmd.command already carries the `?`)
    // then hides the palette (commands.js:494). For the public set there are no
    // subcommands, so the trailing space closes the token and the palette stays
    // hidden until the user types a fresh `?`.
    _controller.value = TextEditingValue(
      text: '${cmd.command} ',
      selection: TextSelection.collapsed(offset: cmd.command.length + 1),
    );
    _hideOverlay();
    _focus.requestFocus();
  }

  int get _navItemCount {
    if (_paletteActive) return paletteCommands(_paletteRows).length;
    if (_botPaletteActive) return _botRows.length;
    return _acView?.itemCount ?? 0;
  }

  void _confirmSelection() {
    if (_paletteActive) {
      final cmds = paletteCommands(_paletteRows);
      if (_selectedIndex >= 0 && _selectedIndex < cmds.length) {
        _completeCommand(cmds[_selectedIndex]);
      }
      return;
    }
    if (_botPaletteActive) {
      if (_selectedIndex >= 0 && _selectedIndex < _botRows.length) {
        _completeBotCommand(_botRows[_selectedIndex]);
      }
      return;
    }
    final v = _acView;
    if (v == null) return;
    switch (v.kind) {
      case AutocompleteKind.mention:
        if (_selectedIndex < v.mentions.length) {
          _replaceTriggerToken(v.mentions[_selectedIndex].insertText);
        }
      case AutocompleteKind.channel:
        if (_selectedIndex < v.channels.length) {
          _replaceTriggerToken(v.channels[_selectedIndex].insertText);
        }
      case AutocompleteKind.emoji:
        if (_selectedIndex < v.emoji.length) {
          _onEmojiAutocompletePicked(v.emoji[_selectedIndex]);
        }
      case AutocompleteKind.kaomoji:
        final items = v.kaomojiItems;
        if (_selectedIndex < items.length) {
          _replaceTriggerToken(kaomojiInsertText(items[_selectedIndex]));
        }
    }
  }

  void _onEmojiAutocompletePicked(EmojiResult e) {
    _replaceTriggerToken(e.insertText);
    // Bump recents like selectSpecificEmojiAutocomplete (addToRecentEmojis).
    unawaitedRecents(e.emoji);
  }

  void unawaitedRecents(String emoji) async {
    final prefs = await _ensurePrefs();
    final next = await EmojiRecentsStore(prefs).add(emoji);
    if (!mounted) return;
    setState(() => _recents = next);
  }

  /// Intercepts arrow/Enter/Tab/Esc while a dropdown is open (navigate*/select*).
  /// Esc also cancels a pending edit/quote chip when no dropdown is open
  /// (ui-context.js:1018, 269-270).
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (!_overlayActive) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_pendingEdit != null) {
          _cancelEdit();
          return KeyEventResult.handled;
        }
        if (_pendingQuote != null) {
          _clearQuote();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final count = _navItemCount;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _selectedIndex = wrapIndex(_selectedIndex, 1, count));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _selectedIndex = wrapIndex(_selectedIndex, -1, count));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.tab) {
      _confirmSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _hideOverlay();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _send() {
    final typed = _controller.text;
    final controller = ref.read(nostrControllerProvider);

    // Edit mode: route the (next) send to editMessage and exit edit mode
    // (messages.js send path checks `this.pendingEdit`). Empty input cancels.
    final edit = _pendingEdit;
    if (edit != null) {
      final trimmed = typed.trim();
      setState(() => _pendingEdit = null);
      _controller.clear();
      _hideOverlay();
      _focus.requestFocus();
      if (trimmed.isEmpty || trimmed == edit.content.trim()) return;
      controller.editMessage(edit.messageId, trimmed);
      return;
    }

    // Nothing to send unless there's typed text OR a pending quote (the PWA
    // allows sending a bare quote: `if (!content && !this.pendingQuote) return`).
    if (typed.trim().isEmpty && _pendingQuote == null) return;

    final content = _composeOutgoing(typed);

    // Routes through the NostrController: optimistic local echo + relay
    // publish when an identity is live, falling back to local echo otherwise.
    // `?`/@Nymbot interception and `/` commands are handled inside sendCurrent.
    controller.sendCurrent(content);
    _controller.clear();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  /// Prepends the pending quote to [typed] ONLY at send (messages.js:2354-2361):
  /// first quoted line as `> @author: line`, remaining lines each `> line`, then
  /// a blank line before the user's text. Clears the consumed quote chip.
  String _composeOutgoing(String typed) {
    var content = typed;
    final quote = _pendingQuote;
    if (quote != null) {
      final lines = quote.text.split('\n');
      final quoteRest = lines.length > 1
          ? '\n${lines.skip(1).map((l) => '> $l').join('\n')}'
          : '';
      final quoteLine = '> @${quote.author}: ${lines.first}$quoteRest';
      content = content.isNotEmpty ? '$quoteLine\n\n$content' : quoteLine;
      _pendingQuote = null;
    }
    return content;
  }

  /// SEND long-press → pseudonymous "ANON" send (ui-context.js:1208-1225 →
  /// messages.js `sendMessagePseudonymous`). Publishes the current draft signed
  /// with a FRESH ephemeral keypair instead of the durable identity, so the
  /// message is unlinkable to the user's nym. Only Nostr-login (durable)
  /// identities can do this in the PWA (`if (this.nostrLoginMethod)`); ephemeral
  /// geohash keys are already pseudonymous, so the affordance is gated off for
  /// them (see [_anonEligible]). Quote/edit are handled exactly like a normal
  /// send. Routed through the real controller method (CROSS_FILE_NEEDS: the
  /// controller must expose `sendCurrentPseudonymous`).
  void _sendAnon() {
    final typed = _controller.text;
    // Edit-in-progress isn't a pseudonymous flow in the PWA (the long-press still
    // calls sendMessagePseudonymous which ignores edit state) — fall back to the
    // normal send so an in-flight edit is never silently dropped.
    if (_pendingEdit != null) {
      _send();
      return;
    }
    if (typed.trim().isEmpty && _pendingQuote == null) return;
    final controller = ref.read(nostrControllerProvider);
    final content = _composeOutgoing(typed);
    // Real ephemeral-key publish lives in the controller (shared core). Dispatch
    // dynamically so the build stays green until the typed method lands; if it's
    // genuinely absent we surface the real "unavailable" state rather than
    // silently publishing under the user's real key (a privacy regression).
    try {
      (controller as dynamic).sendCurrentPseudonymous(content);
    } on NoSuchMethodError {
      _onSystemMessage('Anonymous send is not available yet.');
      return;
    }
    _controller.clear();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  /// Whether the SEND long-press anon affordance applies: a durable Nostr-login
  /// identity (`this.nostrLoginMethod`, ui-context.js:1215). Ephemeral geohash
  /// keys are already anonymous so the PWA doesn't offer it for them.
  bool get _anonEligible =>
      ref.read(nostrControllerProvider).identity?.loginMethod != null;

  // --- Attachments: image upload (Blossom) + P2P file share -----------------

  /// `#uploadProgress` state (0..1, null = hidden). Mirrors the PWA's progress
  /// bar shown during `uploadImage` (users.js:971).
  double? _uploadProgress;

  /// Set by the cancel ✕ (`cancelUpload`) so an in-flight upload, once it
  /// resolves, is discarded instead of appended (the underlying
  /// `uploadImage` future isn't cancellable — F11).
  bool _uploadCancelled = false;

  /// 1-based index + total of the current multi-file upload (users.js:1006-1008
  /// labels "Uploading i of N…" when N>1). 0/0 = single-file (no "of N").
  int _uploadIndex = 0;
  int _uploadTotal = 0;

  void _cancelUpload() {
    setState(() {
      _uploadCancelled = true;
      _uploadProgress = null;
      _uploadMime = null;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
  }

  /// Image/Video button (`selectImage` → fileInput `multiple`, accepts image +
  /// video): pick one OR MANY media, upload each to a Blossom server, then append
  /// ALL resulting URLs (space-joined) to the input — the formatter renders them
  /// as media (users.js:971-1028). For multi-select the progress label reads
  /// "Uploading i of N…".
  Future<void> _pickAndUploadImage() async {
    List<XFile> picked;
    try {
      final picker = ImagePicker();
      // `pickMultipleMedia` returns image OR video files (PWA
      // accept="image/*,video/…" `multiple`).
      picked = await picker.pickMultipleMedia();
    } catch (_) {
      return; // picker unavailable (tests/desktop)
    }
    if (picked.isEmpty) return;
    const maxUpload = 50 * 1024 * 1024; // 50 MB cap (users.js:977)

    if (!mounted) return;
    setState(() {
      _uploadCancelled = false;
      _uploadTotal = picked.length;
    });

    final controller = ref.read(nostrControllerProvider);
    final urls = <String>[];
    for (var i = 0; i < picked.length; i++) {
      if (!mounted || _uploadCancelled) break;
      final file = picked[i];
      final Uint8List bytes;
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        continue;
      }
      if (bytes.length > maxUpload) {
        _onSystemMessage('Files must be under 50MB.');
        continue;
      }
      final contentType = file.mimeType ?? _guessImageMime(file.name);
      if (!mounted) return;
      setState(() {
        _uploadProgress = 0.1;
        _uploadMime = contentType;
        _uploadIndex = i + 1;
      });
      final url = await controller.uploadImage(
        bytes,
        contentType: contentType,
        onProgress: (p) {
          if (mounted && !_uploadCancelled) setState(() => _uploadProgress = p);
        },
      );
      if (!mounted) return;
      if (_uploadCancelled) break;
      if (url == null) {
        _onSystemMessage('Failed to upload media.');
        continue;
      }
      urls.add(url);
    }

    if (!mounted) return;
    final wasCancelled = _uploadCancelled;
    setState(() {
      _uploadProgress = null;
      _uploadMime = null;
      _uploadCancelled = false;
      _uploadIndex = 0;
      _uploadTotal = 0;
    });
    // Drop the results entirely if the user pressed ✕ mid-batch.
    if (wasCancelled || urls.isEmpty) return;
    // Append all URLs space-joined (then a trailing space), like the PWA.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}${urls.join(' ')} ';
    _controller.selection =
        TextSelection.collapsed(offset: _controller.text.length);
    setState(() {});
    _focus.requestFocus();
  }

  /// File button (`selectP2PFile` → p2pFileInput): pick any file and offer it as
  /// a P2P transfer (`shareP2PFile`, p2p.js:86).
  Future<void> _pickAndShareFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(withData: true);
    } catch (_) {
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _onSystemMessage('Could not read the selected file.');
      return;
    }
    await ref.read(nostrControllerProvider).shareP2PFile(
          bytes: bytes,
          name: file.name,
          type: _guessImageMime(file.name),
        );
    if (mounted) _onSystemMessage('File offered for P2P download.');
  }

  static String _guessImageMime(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    return 'application/octet-stream';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `#sendBtn` is gated on CONNECTION, not input content: the PWA flips
    // `disabled=false` once an identity/relay connects (relays.js:1040/1169/1276)
    // and never re-disables it for an empty field. The empty-input guard lives
    // inside `_send`/`_sendAnon` only (matching `if (!content && !pendingQuote)`).
    final sendEnabled = ref.watch(
          appStateProvider.select((s) => s.connectedRelays > 0),
        ) ||
        ref.read(nostrControllerProvider).isLive;

    // Keep the live NIP-30 custom-emoji snapshot in sync so the open emoji
    // picker / `:` autocomplete refresh when packs arrive over relays.
    _customEmojis = ref.watch(liveCustomEmojiProvider);

    // Apply mention/quote requests published by the context menu (one-shot).
    ref.listen(pendingComposerActionProvider, (_, action) {
      if (action == null) return;
      _applyComposerAction(action);
      ref.read(pendingComposerActionProvider.notifier).consume();
    });
    // Apply edit requests published by the context menu (one-shot, F2).
    ref.listen(pendingEditProvider, (_, edit) {
      if (edit == null) return;
      _applyEdit(edit);
      ref.read(pendingEditProvider.notifier).consume();
    });

    final input = _inputWithChips(context);
    // `.input-container` is `padding: 12px 16px` (desktop/tablet); the phone
    // breakpoint (≤768) collapses it to a flat `padding: 10px`
    // (styles-themes-responsive.css:221/304). `compact` spans the whole ≤1024
    // off-canvas range, so key the 10px override off the real phone width.
    final phone =
        MediaQuery.of(context).size.width <= NymDimens.mobileBreakpoint;
    final toolbar = _toolbar(context, sendEnabled, phone);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      padding: phone
          ? const EdgeInsets.all(10)
          : const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_uploadProgress != null) _uploadBar(context),
            widget.compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      input,
                      const SizedBox(height: 10),
                      toolbar,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: input),
                      const SizedBox(width: 10),
                      toolbar,
                    ],
                  ),
          ],
        ),
      ),
    );
  }

  /// The input column with the quote/edit preview chip stacked above it
  /// (`.quote-preview` / `.edit-preview`, `bottom:100%`). The chip slides in
  /// (0.2s, dy 8→0) and the column height animates so the input shifts down.
  Widget _inputWithChips(BuildContext context) {
    final chip = _pendingEdit != null
        ? _EditPreviewChip(
            text: _quotePreviewText(_pendingEdit!.content),
            onClose: _cancelEdit,
          )
        : (_pendingQuote != null
            ? _QuotePreviewChip(
                author: _pendingQuote!.author,
                text: _quotePreviewText(_pendingQuote!.text),
                onClose: _clearQuote,
              )
            : null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: Alignment.bottomLeft,
          child: chip == null
              ? const SizedBox(height: 0)
              : Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: chip,
                ),
        ),
        _input(context),
      ],
    );
  }

  /// `.upload-progress` — a panel (bg glass-bg, glass border, top corners
  /// radius-sm, 12px padding, 8px bottom gap) floating above the input with a
  /// label + cancel ✕ + a thin gradient progress bar (users.js:988-1008).
  /// Single: "Uploading image..." / "Uploading video..."; multi: "Uploading
  /// i of N...". The bar fills primary→secondary.
  Widget _uploadBar(BuildContext context) {
    final c = context.nym;
    final isVideo = (_uploadMime ?? '').startsWith('video/');
    final kind = isVideo ? 'video' : 'image';
    final label = _uploadTotal > 1
        ? 'Uploading $_uploadIndex of $_uploadTotal...'
        : 'Uploading $kind...';
    final fraction = (_uploadProgress ?? 0.1).clamp(0.0, 1.0);
    return Container(
      // `.upload-progress`: bg var(--bg-tertiary) (rgba(20,20,35,0.9) dark /
      // #1c1c2c solid-ui); `body.light-mode .upload-progress` → white@0.92
      // (styles-themes-responsive.css:1179). border 1px glass, radius-sm top
      // corners, padding 12, margin-bottom 8.
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.isLight ? Colors.white.withValues(alpha: 0.92) : c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(NymRadius.sm)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ),
              // `.upload-progress-close` (22×22 ✕, radius-sm), cancels the
              // in-flight upload.
              Material(
                type: MaterialType.transparency,
                borderRadius: NymRadius.rsm,
                child: InkWell(
                  onTap: _cancelUpload,
                  borderRadius: NymRadius.rsm,
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Center(
                      child: NymSvgIcon(NymIcons.close, size: 14, color: c.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // `.progress-bar`: height 6, bg rgba(255,255,255,0.05), radius 10;
          // `.progress-fill`: linear-gradient(90deg, primary, secondary).
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 6,
              color: Colors.white.withValues(alpha: 0.05),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      gradient: LinearGradient(
                        colors: [c.primary, c.secondary],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `.message-input` wrapped with the autocomplete/command-palette overlay
  /// anchored above it (`bottom: 100%` like the PWA's inline dropdowns).
  Widget _input(BuildContext context) {
    return CompositedTransformTarget(
      link: _acAnchor,
      child: OverlayPortal(
        controller: _acPortal,
        overlayChildBuilder: _overlayChild,
        child: Focus(
          onKeyEvent: _onKey,
          child: _textField(context),
        ),
      ),
    );
  }

  /// The anchored dropdown — either the command palette or one of the four
  /// autocompletes — positioned above the input, full-width.
  Widget _overlayChild(BuildContext context) {
    if (!_overlayActive) return const SizedBox.shrink();
    final body = _paletteActive
        ? CommandPalette(
            rows: _paletteRows,
            selectedIndex: _selectedIndex,
            onSelect: _completeCommand,
          )
        : _botPaletteActive
        ? BotCommandPalette(
            rows: _botRows,
            selectedIndex: _selectedIndex,
            onSelect: _completeBotCommand,
          )
        : AutocompleteDropdown(
            view: _acView!,
            selectedIndex: _selectedIndex,
            custom: _customEmojis,
            badgesFor: _mentionBadges,
            cosmeticsFor: (pk) => resolveCosmetics(ref, pk),
            onSelectMention: (m) => _replaceTriggerToken(m.insertText),
            onSelectChannel: (ch) => _replaceTriggerToken(ch.insertText),
            onSelectEmoji: _onEmojiAutocompletePicked,
            onSelectKaomoji: (k) => _replaceTriggerToken(kaomojiInsertText(k)),
          );
    return CompositedTransformFollower(
      link: _acAnchor,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      showWhenUnlinked: false,
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Material(
          type: MaterialType.transparency,
          child: SizedBox(
            width: _anchorWidth(context),
            child: body,
          ),
        ),
      ),
    );
  }

  double _anchorWidth(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.size.width ?? MediaQuery.sizeOf(context).width;
  }

  /// Resolves the verified/friend badge flags for a mention row (F3). Verified
  /// = verified developer OR Nymbot (Foundations `isVerifiedDeveloper/Bot`);
  /// friend = in the friend set (`appState.isFriend`).
  MentionBadges _mentionBadges(String pubkey) {
    final controller = ref.read(nostrControllerProvider);
    final verified =
        controller.isVerifiedDeveloper(pubkey) || controller.isVerifiedBot(pubkey);
    final friend = ref.read(appStateProvider).isFriend(pubkey);
    return (verified: verified, friend: friend);
  }

  /// `.message-input` (+ `.message-input-row` with the translate button). When
  /// the draft is tall enough the field takes the `.composer-popout` treatment:
  /// bg-tertiary fill, primary@0.3 border, shadow-lg (F8). The 26×26 translate
  /// button + 230px language dropdown overlay the bottom-right (F7).
  Widget _textField(BuildContext context) {
    final c = context.nym;
    final hasText = _controller.text.trim().isNotEmpty;
    final focused = _focus.hasFocus;
    // `.composer-popout .message-input`: elevated rounded box vs the flat field.
    // `.message-input` flat fill is white@0.05 → white@0.07 on focus (dark); in
    // light mode `body.light-mode div.message-input` flips to black@0.04 →
    // black@0.02 on focus (styles-themes-responsive.css:62-67).
    final flatFill = c.isLight
        ? Colors.black.withValues(alpha: focused ? 0.02 : 0.04)
        : Colors.white.withValues(alpha: focused ? 0.07 : 0.05);
    final fill = _popout ? c.bgTertiary : flatFill;
    // `.message-input` rounds ONLY the bottom corners when flat (chips/dropdowns
    // sit `bottom:100%` flush above it — styles-chat.css:1666); the popout box
    // uses full radius-md (styles-chat.css:1737).
    final radius = _popout
        ? NymRadius.rmd
        : const BorderRadius.vertical(bottom: Radius.circular(NymRadius.md));
    final border = OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: _popout ? c.primaryA(0.30) : c.glassBorder),
    );
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: _popout ? 12 : 5,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      onChanged: (_) {
        _onInputChanged();
        // Emit a typing indicator on real keystrokes (PWA sends kind-69420
        // 'start' on input). `sendTypingStart` self-throttles to ~1/s, gates on
        // the typing-scope setting, and no-ops in channel views, so calling it
        // every keystroke is safe. (`messages.js` typing emit on input.)
        ref.read(nostrControllerProvider).sendTypingStart();
      },
      style: TextStyle(
        // `.message-input` text is forced pure white (dark) / pure black (light)
        // — `color:#ffffff !important` / `body.light-mode … color:#000000`
        // (styles-themes-responsive.css:578-593), NOT the accent `--text`.
        color: c.isLight ? Colors.black : Colors.white,
        fontSize: widget.compact ? 16 : 15,
      ),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        // PWA `data-placeholder` teaches the `/` and `?` affordances (F9).
        hintText: 'Message, / for commands, ? for Nymbot...',
        hintStyle: TextStyle(
            // `div.message-input:empty::before` → white@0.4 (dark) /
            // black@0.4 (`body.light-mode …`, styles-themes-responsive.css:58).
            color: (c.isLight ? Colors.black : Colors.white)
                .withValues(alpha: 0.4),
            fontSize: widget.compact ? 16 : 15),
        filled: true,
        fillColor: fill,
        // The translate button only exists when there's text (A9), so only then
        // does the input reserve right padding for it (`paddingRight 38px`).
        contentPadding: EdgeInsets.fromLTRB(16, 10, hasText ? 38 : 16, 10),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: radius,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );

    final stack = Stack(
      children: [
        field,
        // `#translateInputBtn` starts `.nm-hidden` and `display:flex` ONLY when
        // the field has text (translate.js:588-600). Render it solely then — no
        // faded ghost when empty.
        if (hasText)
          Positioned(
            right: 8,
            bottom: 10,
            child: _translateButton(context),
          ),
      ],
    );

    if (!_popout) {
      // `.message-input:focus`: a 3px primary@0.06 focus ring (spread, no blur)
      // hugging the field's rounded-bottom shape.
      if (!focused) return stack;
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: c.primaryA(0.06),
              spreadRadius: 3,
              blurRadius: 0,
            ),
          ],
        ),
        child: stack,
      );
    }
    // The popout box is elevated (shadow-lg) and height-capped (min 40vh,360).
    return Container(
      constraints: BoxConstraints(
        maxHeight: math.min(MediaQuery.sizeOf(context).height * 0.4, 360),
      ),
      decoration: const BoxDecoration(
        borderRadius: NymRadius.rmd,
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: stack,
    );
  }

  /// `#translateInputBtn` (+ its dropdown). Disabled while empty; pulses while
  /// translating. Anchors the 230px language dropdown above it.
  Widget _translateButton(BuildContext context) {
    final hasText = _controller.text.trim().isNotEmpty;
    return CompositedTransformTarget(
      link: _translateAnchor,
      child: OverlayPortal(
        controller: _translatePortal,
        overlayChildBuilder: _translateDropdown,
        child: _TranslateInputButton(
          enabled: hasText && !_translating,
          translating: _translating,
          onTap: _toggleTranslateDropdown,
        ),
      ),
    );
  }

  void _toggleTranslateDropdown() {
    if (_translatePortal.isShowing) {
      _translatePortal.hide();
      return;
    }
    if (_controller.text.trim().isEmpty || _translating) return;
    _emojiPortal.hide();
    _gifPortal.hide();
    setState(() {
      _translateQuery = '';
      // Snapshot the favorites-pinned order at open (re-pins only on reopen).
      _translateLangOrder =
          sortedTranslateLanguagesWithFavorites(_translateFavorites);
    });
    _translateSearchController.clear();
    _translatePortal.show();
  }

  /// `.translate-input-dropdown`: a 230px search + language list anchored above
  /// the translate button. Choosing a language translates the draft in place.
  Widget _translateDropdown(BuildContext context) {
    final c = context.nym;
    final q = _translateQuery.trim().toLowerCase();
    // Star FILL reads the live favorites set; row ORDER uses the open-time
    // snapshot so toggling a star doesn't reshuffle mid-open (PWA parity).
    final favSet = _translateFavorites.toSet();
    final order = _translateLangOrder.isEmpty
        ? sortedTranslateLanguagesWithFavorites(_translateFavorites)
        : _translateLangOrder;
    final langs = order
        .where((e) => q.isEmpty || e.value.toLowerCase().contains(q))
        .toList();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _translatePortal.hide,
          ),
        ),
        CompositedTransformFollower(
          link: _translateAnchor,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -4),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Material(
              type: MaterialType.transparency,
              child: Container(
                width: 230,
                constraints: const BoxConstraints(maxHeight: 320),
                decoration: BoxDecoration(
                  color: c.bgSecondary,
                  border: Border.all(color: c.glassBorder),
                  borderRadius: NymRadius.rmd,
                  // `.translate-input-dropdown`: 0 8px 24px rgba(0,0,0,0.4).
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x66000000),
                        blurRadius: 24,
                        offset: Offset(0, 8)),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // `.translate-dropdown-search`: 8px padding + a bottom
                    // hairline divider under the search region.
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border(
                            bottom: BorderSide(color: c.glassBorder)),
                      ),
                      child: TextField(
                        controller: _translateSearchController,
                        autofocus: true,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.text, fontSize: 13),
                        cursorColor: c.primary,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search languages...',
                          hintStyle: TextStyle(color: c.textDim, fontSize: 13),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.05),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          border: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.glassBorder),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: NymRadius.rsm,
                            borderSide: BorderSide(color: c.primary),
                          ),
                        ),
                      ),
                    ),
                    Flexible(
                      // `.translate-dropdown-list`: padding 4px 0.
                      child: langs.isEmpty
                          ? Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text('No languages found',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: c.textDim, fontSize: 13)),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4),
                              itemCount: langs.length,
                              itemBuilder: (_, i) {
                                final e = langs[i];
                                return _TranslateLangRow(
                                  name: e.value,
                                  favorited: favSet.contains(e.key),
                                  onTap: () => _translateDraft(e.key),
                                  onToggleFavorite: () =>
                                      _toggleTranslateFavorite(e.key),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Translates the typed draft into [targetLang] and replaces the input text
  /// (the PWA's in-input translate flow). The quote/edit chips are preserved.
  Future<void> _translateDraft(String targetLang) async {
    _translatePortal.hide();
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    setState(() => _translating = true);
    try {
      final res = await TranslateService().translate(text, targetLang);
      if (!mounted) return;
      final out = res.translatedText.trim();
      if (out.isNotEmpty) {
        _controller.text = out;
        _controller.selection =
            TextSelection.collapsed(offset: _controller.text.length);
      }
    } catch (_) {
      if (mounted) _onSystemMessage('Translation failed.');
    } finally {
      if (mounted) {
        setState(() => _translating = false);
        _onInputChanged();
      }
    }
  }

  /// `.input-buttons`: image / file / emoji / GIF icon buttons + SEND.
  Widget _toolbar(BuildContext context, bool sendEnabled, bool phone) {
    final buttons = <Widget>[
      _IconBtn(
        svg: NymIcons.composerImage,
        tooltip: 'Upload Image/Video',
        expand: widget.compact,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _IconBtn(
        svg: NymIcons.composerFile,
        tooltip: 'Share File (P2P)',
        expand: widget.compact,
        onTap: _pickAndShareFile,
      ),
      _emojiButton(context),
      _gifButton(context),
      // The PWA's `.input-buttons` (index.html:758-790) has EXACTLY 5 children:
      // Image, File, Emoji, GIF, SEND — there is NO Nymbot toolbar button (bot
      // access is via `?`/@Nymbot in the input, routed inside `sendCurrent`).
      _SendButton(
        enabled: sendEnabled,
        onTap: _send,
        // Long-press → ANON pseudonymous send, only for durable Nostr-login
        // identities (ephemeral geohash keys are already anonymous).
        onAnon: _anonEligible ? _sendAnon : null,
        expand: widget.compact,
        // Phone (≤768) shrinks SEND to `padding:10px` / `font-size:11px`
        // (styles-themes-responsive.css:341).
        phone: phone,
      ),
    ];

    if (widget.compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            // SEND gets flex:2, others flex:1.
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            // Stacked `.input-buttons` is `gap:10px` (≤1024 + ≤768 overrides,
            // styles-themes-responsive.css:325/487), not the desktop 5px.
            if (i != buttons.length - 1) const SizedBox(width: 10),
          ],
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < buttons.length; i++) ...[
          buttons[i],
          if (i != buttons.length - 1) const SizedBox(width: 5),
        ],
      ],
    );
  }

  /// Emoji toolbar button + its inline popover anchored above the button.
  Widget _emojiButton(BuildContext context) {
    return CompositedTransformTarget(
      link: _emojiAnchor,
      child: OverlayPortal(
        controller: _emojiPortal,
        // The picker reads `liveCustomEmojiProvider` directly, so it surfaces
        // relay-sourced packs live — no override needed.
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _emojiPortal.hide,
          child: EmojiPicker(
            recents: _recents,
            onSelect: _onEmojiSelected,
          ),
        ),
        child: _IconBtn(
          svg: NymIcons.composerEmoji,
          tooltip: 'Emoji',
          expand: widget.compact,
          onTap: _toggleEmojiPicker,
        ),
      ),
    );
  }

  /// GIF toolbar button + its inline popover anchored above the button.
  Widget _gifButton(BuildContext context) {
    return CompositedTransformTarget(
      link: _gifAnchor,
      child: OverlayPortal(
        controller: _gifPortal,
        overlayChildBuilder: (context) => _popover(
          link: _gifAnchor,
          onDismiss: _gifPortal.hide,
          child: GifPicker(
            favoritesStore: FavoriteGifsStore(_prefs!),
            onSelect: _onGifSelected,
            onClose: _gifPortal.hide,
          ),
        ),
        child: _IconBtn(
          label: 'GIF',
          tooltip: 'GIF',
          expand: widget.compact,
          onTap: _toggleGifPicker,
        ),
      ),
    );
  }

  /// Positions a picker above its anchor button (bottom-anchored, like the
  /// PWA's `bottom: 100%` inline popup) with a barrier to dismiss on tap-out.
  Widget _popover({
    required LayerLink link,
    required VoidCallback onDismiss,
    required Widget child,
  }) {
    final media = MediaQuery.of(context);
    // `.emoji-picker`/`.gif-picker` @media (max-width:768): `position: fixed;
    // left: 50%; transform: translateX(-50%); bottom: 60px; max-width: 90%` —
    // centered above the input bar on phones (vs anchored above the button on
    // desktop, base `bottom: 100%`).
    final isPhone = media.size.width <= NymDimens.mobileBreakpoint;
    final picker = Material(type: MaterialType.transparency, child: child);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        if (isPhone)
          Positioned(
            left: 8,
            right: 8,
            // 60px above the bar, lifted above the keyboard when it's open.
            bottom: 60 + media.viewInsets.bottom,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: picker,
              ),
            ),
          )
        else
          CompositedTransformFollower(
            link: link,
            targetAnchor: Alignment.topRight,
            followerAnchor: Alignment.bottomRight,
            offset: const Offset(0, -8),
            showWhenUnlinked: false,
            child: Align(
              alignment: Alignment.bottomRight,
              child: picker,
            ),
          ),
      ],
    );
  }
}

/// `.icon-btn.input-btn`: height 42, 18×18 icon stroke text→primary, radius sm.
class _IconBtn extends StatefulWidget {
  const _IconBtn({
    this.svg,
    this.label,
    required this.tooltip,
    this.expand = false,
    this.onTap,
  }) : assert(svg != null || label != null, 'provide an svg or a label');
  /// The exact-PWA glyph markup (image/file/emoji), or null for a [label] button.
  final String? svg;

  /// A text glyph instead of an SVG — the PWA's GIF button is the literal "GIF"
  /// text (`<text>GIF</text>`), which flutter_svg can't render, so it's drawn as
  /// styled text here.
  final String? label;
  final String tooltip;
  final bool expand;
  final VoidCallback? onTap;

  @override
  State<_IconBtn> createState() => _IconBtnState();
}

class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // `.icon-btn.input-btn`: transparent (no bg/border), 42 tall, 0 12 padding,
    // radius sm. The icon stroke goes text→primary on hover (F10).
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Material(
          color: Colors.transparent,
          borderRadius: NymRadius.rsm,
          child: InkWell(
            onTap: widget.onTap ?? () {},
            borderRadius: NymRadius.rsm,
            child: Container(
              height: 42,
              constraints: const BoxConstraints(minWidth: 42),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              child: widget.label != null
                  ? Text(
                      widget.label!,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: _hover ? c.primary : c.text,
                      ),
                    )
                  : NymSvgIcon(
                      widget.svg!,
                      size: 18,
                      color: _hover ? c.primary : c.text,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `.send-btn`: primary@10 bg, primary@30 border, radius sm, "SEND" 12px
/// uppercase letter-spacing 1.5 weight 600. Disabled opacity 0.35. On hover
/// the bg lifts to primary@18 with a primary@10 glow (F10).
///
/// When [onAnon] is non-null a 2s press-and-hold fires the pseudonymous "ANON"
/// send (ui-context.js:1202-1264): a 700ms pre-glow (primary@0.2) telegraphs the
/// press, then at 2s the label swaps to "ANON" with a primary@0.4 glow + haptic,
/// [onAnon] runs, and after 1s it reverts to "SEND". The trailing click is
/// suppressed so the hold doesn't also fire a normal send.
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.enabled,
    required this.onTap,
    this.onAnon,
    this.expand = false,
    this.phone = false,
  });
  final bool enabled;
  final VoidCallback onTap;

  /// Long-press (2s) pseudonymous send. Null = no anon affordance (the hold then
  /// does nothing special; a tap still sends normally).
  final VoidCallback? onAnon;
  final bool expand;

  /// Phone (≤768) shrinks the button to `padding:10px` / `font-size:11px`.
  final bool phone;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;

  // Long-press state (ui-context.js sendLongPressTimer/Fired/SuppressClickUntil).
  Timer? _holdTimer;
  Timer? _preGlowTimer;
  Timer? _revertTimer;
  bool _anonFired = false;
  bool _preGlow = false;
  DateTime _suppressClickUntil = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _holdTimer?.cancel();
    _preGlowTimer?.cancel();
    _revertTimer?.cancel();
    super.dispose();
  }

  void _startHold() {
    if (widget.onAnon == null || !widget.enabled) return;
    if (_holdTimer != null) return;
    _anonFired = false;
    // 700ms pre-glow telegraph (primary@0.2).
    _preGlowTimer = Timer(const Duration(milliseconds: 700), () {
      if (_holdTimer != null && mounted) setState(() => _preGlow = true);
    });
    // 2s → fire ANON.
    _holdTimer = Timer(const Duration(seconds: 2), () {
      _holdTimer = null;
      _preGlowTimer?.cancel();
      if (!mounted) return;
      _anonFired = true;
      _suppressClickUntil =
          DateTime.now().add(const Duration(milliseconds: 800));
      HapticFeedback.mediumImpact();
      setState(() => _preGlow = true);
      widget.onAnon!.call();
      // Revert label + glow after 1s.
      _revertTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() {
          _anonFired = false;
          _preGlow = false;
        });
      });
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _preGlowTimer?.cancel();
    if (!_anonFired && mounted && _preGlow) setState(() => _preGlow = false);
  }

  void _handleTap() {
    // Suppress the click that follows a fired long-press (ui-context.js:1250).
    if (_anonFired || DateTime.now().isBefore(_suppressClickUntil)) return;
    if (widget.enabled) widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovering = _hover && widget.enabled;
    // Glow: 700ms pre-glow → primary@0.2; fired → primary@0.4; hover → @0.1.
    final List<BoxShadow>? glow = _preGlow
        ? [
            BoxShadow(
                color: c.primaryA(_anonFired ? 0.4 : 0.2),
                blurRadius: _anonFired ? 15 : 10),
          ]
        : (hovering
            ? [BoxShadow(color: c.primaryA(0.10), blurRadius: 15)]
            : null);
    return Opacity(
      opacity: widget.enabled ? 1 : 0.35,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Listener(
          onPointerDown: (_) => _startHold(),
          onPointerUp: (_) => _cancelHold(),
          onPointerCancel: (_) => _cancelHold(),
          child: AnimatedContainer(
            duration: NymMotion.transition,
            curve: NymMotion.curve,
            decoration: BoxDecoration(
              color: c.primaryA(hovering ? 0.18 : 0.10),
              borderRadius: NymRadius.rsm,
              border: Border.all(color: c.primaryA(0.30)),
              boxShadow: glow,
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: NymRadius.rsm,
              child: InkWell(
                onTap: widget.enabled ? _handleTap : null,
                borderRadius: NymRadius.rsm,
                child: Container(
                  height: 42,
                  // Desktop `.send-btn`: `padding:10px 22px` / `font-size:12px`.
                  // Phone (≤768): `padding:10px` / `font-size:11px`
                  // (styles-themes-responsive.css:341).
                  padding: EdgeInsets.symmetric(
                      horizontal: widget.phone ? 10 : 22),
                  alignment: Alignment.center,
                  child: Text(
                    _anonFired ? 'ANON' : 'SEND',
                    style: TextStyle(
                      color: c.primary,
                      fontSize: widget.phone ? 11 : 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared chrome for the quote/edit preview chips (`.quote-preview` /
/// `.edit-preview`, styles-chat.css:1412): bg-tertiary, glass border, top
/// corners rounded radius-md, shadow-lg, 8×12 padding, a colored left bar, a
/// 2-line content column, and a close ✕ (hover #fff on white@10).
class _PreviewChip extends StatelessWidget {
  const _PreviewChip({
    required this.barColor,
    required this.content,
    required this.onClose,
    required this.closeTooltip,
  });

  final Color barColor;
  final Widget content;
  final VoidCallback onClose;
  final String closeTooltip;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.bgTertiary,
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(NymRadius.md)),
        // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
        boxShadow: const [
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // `.quote-preview-bar`: 3px wide, ≥28 tall, radius 2.
          Container(
            width: 3,
            constraints: const BoxConstraints(minHeight: 28),
            decoration: BoxDecoration(
              color: barColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: content),
          const SizedBox(width: 8),
          // `.quote-preview-close`: 16×16 ✕, dim → #fff on hover.
          _ChipCloseButton(tooltip: closeTooltip, onTap: onClose),
        ],
      ),
    );
  }
}

/// `.quote-preview`: author (primary 12/w600 with a muted `#suffix`) over the
/// truncated quoted text (dim 12, ellipsis).
class _QuotePreviewChip extends StatelessWidget {
  const _QuotePreviewChip({
    required this.author,
    required this.text,
    required this.onClose,
  });

  final String author;
  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hashIdx = author.indexOf('#');
    final base = hashIdx >= 0 ? author.substring(0, hashIdx) : author;
    final suffix = hashIdx >= 0 ? author.substring(hashIdx) : '';
    return _PreviewChip(
      barColor: c.primary,
      onClose: onClose,
      closeTooltip: 'Cancel reply',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          RichText(
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: TextStyle(
                  color: c.primary, fontSize: 12, fontWeight: FontWeight.w600),
              children: [
                TextSpan(text: base),
                if (suffix.isNotEmpty)
                  TextSpan(
                    text: suffix,
                    // `.nym-suffix`: opacity 0.7, font-size 0.9em (≈10.8 of 12),
                    // weight 100 (styles-chat.css:706-710).
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
                      fontSize: 12 * 0.9,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// `.edit-preview`: an amber (`#F0AD4E`) bar + a fixed "Editing message" label
/// (amber 12/w600) over the truncated original text (dim 12).
class _EditPreviewChip extends StatelessWidget {
  const _EditPreviewChip({required this.text, required this.onClose});

  static const Color amber = Color(0xFFF0AD4E);

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return _PreviewChip(
      barColor: amber,
      onClose: onClose,
      closeTooltip: 'Cancel edit',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Editing message',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: amber, fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textDim, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// `.quote-preview-close` / `#editPreviewClose`: 16×16 ✕, dim by default,
/// `#fff` on `white@10` on hover.
class _ChipCloseButton extends StatefulWidget {
  const _ChipCloseButton({required this.tooltip, required this.onTap});
  final String tooltip;
  final VoidCallback onTap;

  @override
  State<_ChipCloseButton> createState() => _ChipCloseButtonState();
}

class _ChipCloseButtonState extends State<_ChipCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              // `.quote-preview-close:hover` is white@0.1 fill + #fff icon
              // (dark); `body.light-mode` flips to black@0.08 fill + `--text`
              // icon (styles-themes-responsive.css:1074). Use mode-aware values.
              color: _hover
                  ? (c.isLight
                      ? Colors.black.withValues(alpha: 0.08)
                      : Colors.white.withValues(alpha: 0.1))
                  : null,
              borderRadius: NymRadius.rxs,
            ),
            child: NymSvgIcon(
              NymIcons.close,
              size: 16,
              color: _hover
                  ? (c.isLight ? c.text : Colors.white)
                  : c.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.translate-input-btn`: a 26×26 translate glyph, dim @0.6, hover → primary on
/// `white@8`. Pulses (opacity) while [translating]; disabled (faded) when the
/// draft is empty.
class _TranslateInputButton extends StatefulWidget {
  const _TranslateInputButton({
    required this.enabled,
    required this.translating,
    required this.onTap,
  });

  final bool enabled;
  final bool translating;
  final VoidCallback onTap;

  @override
  State<_TranslateInputButton> createState() => _TranslateInputButtonState();
}

class _TranslateInputButtonState extends State<_TranslateInputButton>
    with SingleTickerProviderStateMixin {
  bool _hover = false;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    // Created eagerly (not lazily) so a never-translated button still has a
    // controller to dispose — a lazy `late` field would otherwise initialise a
    // ticker against a deactivated State during dispose().
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
  }

  @override
  void didUpdateWidget(covariant _TranslateInputButton old) {
    super.didUpdateWidget(old);
    if (widget.translating && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.translating && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final color = _hover && widget.enabled ? c.primary : c.textDim;
    Widget glyph = NymSvgIcon(NymIcons.translate, size: 16, color: color);
    if (widget.translating) {
      // `.translating` pulse: opacity 0.4 ↔ 0.8.
      glyph = FadeTransition(
        opacity: Tween(begin: 0.4, end: 0.8).animate(_pulse),
        child: glyph,
      );
    }
    return Opacity(
      opacity: widget.enabled ? (_hover ? 1.0 : 0.6) : 0.4,
      child: Tooltip(
        message: 'Translate text',
        child: MouseRegion(
          cursor: widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.enabled ? widget.onTap : null,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hover && widget.enabled
                    ? Colors.white.withValues(alpha: 0.08)
                    : null,
                borderRadius: BorderRadius.circular(4),
              ),
              child: glyph,
            ),
          ),
        ),
      ),
    );
  }
}

/// One `.translate-dropdown-item` row: the language name + a trailing favorite
/// star. The row hovers to `white@0.08` + `--text-bright`; the star is
/// `--text-dim` (hover `white@0.1` + text-bright), and `#f5c518` when favorited
/// (styles-chat.css:1850-1897).
class _TranslateLangRow extends StatefulWidget {
  const _TranslateLangRow({
    required this.name,
    required this.favorited,
    required this.onTap,
    required this.onToggleFavorite,
  });

  final String name;
  final bool favorited;
  final VoidCallback onTap;
  final VoidCallback onToggleFavorite;

  @override
  State<_TranslateLangRow> createState() => _TranslateLangRowState();
}

class _TranslateLangRowState extends State<_TranslateLangRow> {
  bool _hover = false;
  bool _starHover = false;

  static const Color _favColor = Color(0xFFF5C518);

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          color: _hover ? Colors.white.withValues(alpha: 0.08) : null,
          // `.translate-dropdown-item`: padding 7px 8px 7px 14px; gap 8.
          padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _hover ? c.textBright : c.text,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // `.translate-dropdown-star`: 24×24, radius-sm.
              MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _starHover = true),
                onExit: (_) => setState(() => _starHover = false),
                child: GestureDetector(
                  onTap: widget.onToggleFavorite,
                  child: Container(
                    width: 24,
                    height: 24,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _starHover
                          ? Colors.white.withValues(alpha: 0.1)
                          : null,
                      borderRadius: NymRadius.rsm,
                    ),
                    child: NymSvgIcon(
                      widget.favorited
                          ? NymIcons.starFilled
                          : NymIcons.starOutline,
                      size: 14,
                      color: widget.favorited
                          ? _favColor
                          : (_starHover ? c.textBright : c.textDim),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
