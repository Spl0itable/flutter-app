import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../features/autocomplete/autocomplete_dropdown.dart';
import '../../features/autocomplete/autocomplete_queries.dart';
import '../../features/autocomplete/autocomplete_triggers.dart';
import '../../features/autocomplete/pending_edit.dart';
import '../../features/commands/command_palette.dart';
import '../../features/commands/command_registry.dart';
import '../../features/emoji/custom_emoji.dart';
import '../../features/emoji/emoji_data.dart';
import '../../features/emoji/emoji_picker.dart';
import '../../features/emoji/gif_picker.dart';
import '../../features/nymbot/bot_chat_screen.dart';
import '../../features/shop/cosmetics.dart';
import '../../features/translate/translate_languages.dart';
import '../../features/translate/translate_service.dart';
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
  int _selectedIndex = 0;

  bool get _paletteActive => _trigger.kind == TriggerKind.command;
  bool get _acActive => _acView != null && !_acView!.isEmpty;
  bool get _overlayActive => _paletteActive
      ? _paletteRows.isNotEmpty
      : _acActive;

  @override
  void dispose() {
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
    // Register the system-message sink so command feedback surfaces somewhere.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(nostrControllerProvider).setCommandHooks(
            onSystemMessage: _onSystemMessage,
          );
    });
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

  /// Resolve prefs once, then hydrate recents + the cached NIP-30 custom emoji.
  Future<SharedPreferences> _ensurePrefs() async {
    if (_prefs != null) return _prefs!;
    final prefs = await ref.read(emojiPrefsProvider.future);
    _prefs = prefs;
    _recents = EmojiRecentsStore(prefs).load();
    _customEmojis = loadCustomEmojiState(prefs);
    return prefs;
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
      _acView = null;
    } else if (trigger.kind != TriggerKind.none) {
      _paletteRows = const [];
      _acView = _buildAutocompleteView(trigger);
    } else {
      _paletteRows = const [];
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

  int get _navItemCount =>
      _paletteActive ? paletteCommands(_paletteRows).length : (_acView?.itemCount ?? 0);

  void _confirmSelection() {
    if (_paletteActive) {
      final cmds = paletteCommands(_paletteRows);
      if (_selectedIndex >= 0 && _selectedIndex < cmds.length) {
        _completeCommand(cmds[_selectedIndex]);
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

    // Prepend the pending quote ONLY at send (messages.js:2354-2361): first
    // quoted line as `> @author: line`, remaining lines each `> line`, then a
    // blank line before the user's text.
    var content = typed;
    final quote = _pendingQuote;
    if (quote != null) {
      final lines = quote.text.split('\n');
      final quoteLine = '> @${quote.author}: ${lines.first}' +
          (lines.length > 1
              ? '\n${lines.skip(1).map((l) => '> $l').join('\n')}'
              : '');
      content = content.isNotEmpty ? '$quoteLine\n\n$content' : quoteLine;
      _pendingQuote = null;
    }

    // Routes through the NostrController: optimistic local echo + relay
    // publish when an identity is live, falling back to local echo otherwise.
    // `?`/@Nymbot interception and `/` commands are handled inside sendCurrent.
    controller.sendCurrent(content);
    _controller.clear();
    _hideOverlay();
    setState(() {});
    _focus.requestFocus();
  }

  // --- Attachments: image upload (Blossom) + P2P file share -----------------

  /// `#uploadProgress` state (0..1, null = hidden). Mirrors the PWA's progress
  /// bar shown during `uploadImage` (users.js:971).
  double? _uploadProgress;

  /// Set by the cancel ✕ (`cancelUpload`) so an in-flight upload, once it
  /// resolves, is discarded instead of appended (the underlying
  /// `uploadImage` future isn't cancellable — F11).
  bool _uploadCancelled = false;

  void _cancelUpload() {
    setState(() {
      _uploadCancelled = true;
      _uploadProgress = null;
      _uploadMime = null;
    });
  }

  /// Image/Video button (`selectImage` → fileInput, accepts image + video):
  /// pick media, upload it to a Blossom server through the ApiClient, then
  /// append the resulting URL to the input (the formatter renders it as media —
  /// users.js:1022).
  Future<void> _pickAndUploadImage() async {
    Uint8List bytes;
    String contentType;
    try {
      final picker = ImagePicker();
      // pickMedia accepts image OR video (PWA accept="image/*,video/…").
      final picked = await picker.pickMedia();
      if (picked == null) return;
      bytes = await picked.readAsBytes();
      contentType = picked.mimeType ?? _guessImageMime(picked.name);
    } catch (_) {
      return; // picker unavailable (tests/desktop)
    }
    const maxUpload = 50 * 1024 * 1024; // 50 MB cap (users.js:977)
    if (bytes.length > maxUpload) {
      _onSystemMessage('Files must be under 50MB.');
      return;
    }
    if (!mounted) return;
    setState(() {
      _uploadProgress = 0.1;
      _uploadMime = contentType;
      _uploadCancelled = false;
    });
    final url = await ref.read(nostrControllerProvider).uploadImage(
          bytes,
          contentType: contentType,
          onProgress: (p) {
            if (mounted && !_uploadCancelled) setState(() => _uploadProgress = p);
          },
        );
    if (!mounted) return;
    if (_uploadCancelled) {
      // The user pressed ✕ while the upload was in flight — drop the result.
      setState(() => _uploadCancelled = false);
      return;
    }
    setState(() {
      _uploadProgress = null;
      _uploadMime = null;
    });
    if (url == null) {
      _onSystemMessage('Failed to upload media.');
      return;
    }
    // Append the URL to the input (then a trailing space), like the PWA.
    final existing = _controller.text;
    final needsSpace = existing.isNotEmpty && !existing.endsWith(' ');
    _controller.text = '$existing${needsSpace ? ' ' : ''}$url ';
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

  /// Bot-PM entry: binds the private Nymbot chat to the identity and opens
  /// [BotChatScreen] (the paid 1:1 surface). Exposed as a composer affordance
  /// since the PM-list entry is owned elsewhere.
  void _openBotChat() {
    ref.read(nostrControllerProvider).bindBotChat();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const BotChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hasText = _controller.text.trim().isNotEmpty;

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
    final toolbar = _toolbar(context, hasText);

    return Container(
      decoration: BoxDecoration(
        color: c.glassBg,
        border: Border(top: BorderSide(color: c.glassBorder)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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

  /// `#uploadProgress` — a label + thin progress bar + cancel ✕ shown while a
  /// Blossom upload is in flight (users.js:988). The label reflects the picked
  /// media type ("Uploading video…" for `video/*`, else "…image…" — F6).
  Widget _uploadBar(BuildContext context) {
    final c = context.nym;
    final isVideo = (_uploadMime ?? '').startsWith('video/');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(isVideo ? 'Uploading video…' : 'Uploading image…',
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ),
              // `.upload-progress-close` (16×16 ✕), cancels the in-flight upload.
              InkWell(
                onTap: _cancelUpload,
                borderRadius: NymRadius.rxs,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 16, color: c.textDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _uploadProgress,
              minHeight: 4,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(c.primary),
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
    // `.composer-popout .message-input`: elevated rounded box vs the flat field.
    final fill = _popout ? c.bgTertiary : Colors.white.withValues(alpha: 0.05);
    final border = OutlineInputBorder(
      borderRadius: NymRadius.rmd,
      borderSide: BorderSide(color: _popout ? c.primaryA(0.30) : c.glassBorder),
    );
    final field = TextField(
      controller: _controller,
      focusNode: _focus,
      maxLines: _popout ? 12 : 5,
      minLines: 1,
      textInputAction: TextInputAction.newline,
      onChanged: (_) => _onInputChanged(),
      style: TextStyle(
        color: Colors.white,
        fontSize: widget.compact ? 16 : 15,
      ),
      cursorColor: c.primary,
      decoration: InputDecoration(
        isDense: true,
        // PWA `data-placeholder` teaches the `/` and `?` affordances (F9).
        hintText: 'Message, / for commands, ? for Nymbot...',
        hintStyle:
            TextStyle(color: c.textDim, fontSize: widget.compact ? 16 : 15),
        filled: true,
        fillColor: fill,
        // Pad the right so text never sits under the translate button.
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 40, 10),
        border: border,
        enabledBorder: border,
        focusedBorder: OutlineInputBorder(
          borderRadius: NymRadius.rmd,
          borderSide: BorderSide(color: c.primaryA(0.30)),
        ),
      ),
    );

    final stack = Stack(
      children: [
        field,
        // `.translate-input-btn`: 26×26, bottom-right, dim→primary on hover.
        Positioned(
          right: 8,
          bottom: 8,
          child: _translateButton(context),
        ),
      ],
    );

    if (!_popout) return stack;
    // The popout box is elevated (shadow-lg) and height-capped (min 40vh,360).
    return Container(
      constraints: BoxConstraints(
        maxHeight: math.min(MediaQuery.sizeOf(context).height * 0.4, 360),
      ),
      decoration: const BoxDecoration(
        borderRadius: NymRadius.rmd,
        boxShadow: [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
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
    setState(() => _translateQuery = '');
    _translateSearchController.clear();
    _translatePortal.show();
  }

  /// `.translate-input-dropdown`: a 230px search + language list anchored above
  /// the translate button. Choosing a language translates the draft in place.
  Widget _translateDropdown(BuildContext context) {
    final c = context.nym;
    final q = _translateQuery.trim().toLowerCase();
    final langs = sortedTranslateLanguages()
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
                    // `.translate-dropdown-search`.
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: TextField(
                        controller: _translateSearchController,
                        autofocus: true,
                        onChanged: (v) => setState(() => _translateQuery = v),
                        style: TextStyle(color: c.text, fontSize: 13),
                        cursorColor: c.primary,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search language...',
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
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: langs.length,
                        itemBuilder: (_, i) {
                          final e = langs[i];
                          return InkWell(
                            onTap: () => _translateDraft(e.key),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Text(e.value,
                                  style:
                                      TextStyle(color: c.text, fontSize: 13)),
                            ),
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
  Widget _toolbar(BuildContext context, bool hasText) {
    final buttons = <Widget>[
      _IconBtn(
        icon: Icons.image_outlined,
        tooltip: 'Upload Image/Video',
        expand: widget.compact,
        onTap: _uploadProgress != null ? null : _pickAndUploadImage,
      ),
      _IconBtn(
        icon: Icons.attach_file,
        tooltip: 'Share File (P2P)',
        expand: widget.compact,
        onTap: _pickAndShareFile,
      ),
      _emojiButton(context),
      _gifButton(context),
      _IconBtn(
        icon: Icons.smart_toy_outlined,
        tooltip: 'Nymbot',
        expand: widget.compact,
        onTap: _openBotChat,
      ),
      _SendButton(enabled: hasText, onTap: _send, expand: widget.compact),
    ];

    if (widget.compact) {
      return Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            // SEND gets flex:2, others flex:1.
            Expanded(flex: i == buttons.length - 1 ? 2 : 1, child: buttons[i]),
            // `.input-buttons { gap:5px }` (styles-chat.css:1914).
            if (i != buttons.length - 1) const SizedBox(width: 5),
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
        overlayChildBuilder: (context) => _popover(
          link: _emojiAnchor,
          onDismiss: _emojiPortal.hide,
          child: ProviderScope(
            overrides: [
              customEmojiStateProvider.overrideWithValue(_customEmojis),
            ],
            child: EmojiPicker(
              recents: _recents,
              onSelect: _onEmojiSelected,
            ),
          ),
        ),
        child: _IconBtn(
          icon: Icons.emoji_emotions_outlined,
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
          ),
        ),
        child: _IconBtn(
          icon: Icons.gif_box_outlined,
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
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: link,
          targetAnchor: Alignment.topRight,
          followerAnchor: Alignment.bottomRight,
          offset: const Offset(0, -8),
          showWhenUnlinked: false,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Material(
              type: MaterialType.transparency,
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

/// `.icon-btn.input-btn`: height 42, 18×18 icon stroke text→primary, radius sm.
class _IconBtn extends StatefulWidget {
  const _IconBtn({
    required this.icon,
    required this.tooltip,
    this.expand = false,
    this.onTap,
  });
  final IconData icon;
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
              child: Icon(
                widget.icon,
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
class _SendButton extends StatefulWidget {
  const _SendButton({
    required this.enabled,
    required this.onTap,
    this.expand = false,
  });
  final bool enabled;
  final VoidCallback onTap;
  final bool expand;

  @override
  State<_SendButton> createState() => _SendButtonState();
}

class _SendButtonState extends State<_SendButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final hovering = _hover && widget.enabled;
    return Opacity(
      opacity: widget.enabled ? 1 : 0.35,
      child: MouseRegion(
        cursor: widget.enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.forbidden,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: NymMotion.transition,
          curve: NymMotion.curve,
          decoration: BoxDecoration(
            color: c.primaryA(hovering ? 0.18 : 0.10),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.primaryA(0.30)),
            boxShadow: hovering
                ? [
                    BoxShadow(
                        color: c.primaryA(0.10),
                        blurRadius: 15,
                        spreadRadius: 0),
                  ]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: NymRadius.rsm,
            child: InkWell(
              onTap: widget.enabled ? widget.onTap : null,
              borderRadius: NymRadius.rsm,
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 22),
                alignment: Alignment.center,
                child: Text(
                  'SEND',
                  style: TextStyle(
                    color: c.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.5,
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
        boxShadow: const [
          BoxShadow(color: Color(0x66000000), blurRadius: 24, offset: Offset(0, 8)),
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
                    style: TextStyle(
                      color: c.primary.withValues(alpha: 0.7),
                      fontWeight: FontWeight.w100,
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
              color: _hover ? Colors.white.withValues(alpha: 0.1) : null,
              borderRadius: NymRadius.rxs,
            ),
            child: Icon(
              Icons.close,
              size: 16,
              color: _hover ? Colors.white : c.textDim,
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
    Widget glyph = Icon(Icons.translate, size: 16, color: color);
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
