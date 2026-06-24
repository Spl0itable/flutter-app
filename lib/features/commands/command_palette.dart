// Command palette (`#commandPalette`) — the `/` autocomplete. Ports
// `showCommandPalette` (commands.js:364): filters visible commands by the typed
// `/needle` (canonical name OR alias prefix), groups them by category in the
// fixed order, and renders a scrollable dropdown anchored above the input with
// arrow-nav + Enter/Tab to complete. Completion inserts `"<command> "`
// (selectCommand, commands.js:489) — i.e. the canonical name plus a space.

import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import 'command_registry.dart';

/// A flat, navigable palette row (either a category header or a command).
sealed class PaletteRow {
  const PaletteRow();
}

class PaletteHeader extends PaletteRow {
  const PaletteHeader(this.label);
  final String label;
}

class PaletteCommand extends PaletteRow {
  const PaletteCommand(this.spec);
  final CommandSpec spec;
}

/// Filters + groups commands for [input] (the raw `/needle`). Mirrors
/// showCommandPalette: a command matches when its canonical name OR any alias
/// starts with the needle. Returns the grouped rows (headers + commands) in the
/// fixed category order, or an empty list when nothing matches (hide palette).
List<PaletteRow> buildPaletteRows(String input) {
  final needle = input.toLowerCase();
  final matching = visibleCommands().where((spec) {
    if (spec.name.startsWith(needle)) return true;
    return spec.aliases.any((a) => a.startsWith(needle));
  }).toList();

  if (matching.isEmpty) return const [];

  final rows = <PaletteRow>[];
  for (final cat in kCommandCategoryOrder) {
    final items = matching.where((s) => s.category == cat).toList();
    if (items.isEmpty) continue;
    rows.add(PaletteHeader(kCommandCategoryLabels[cat]!));
    rows.addAll(items.map(PaletteCommand.new));
  }
  return rows;
}

/// The selectable command rows only (for index math / Enter selection).
List<CommandSpec> paletteCommands(List<PaletteRow> rows) =>
    rows.whereType<PaletteCommand>().map((r) => r.spec).toList();

/// The `#commandPalette` dropdown. Stateless render; the parent owns the
/// selected index and key handling so it can intercept arrows/Enter/Tab/Esc
/// before the TextField.
class CommandPalette extends StatelessWidget {
  const CommandPalette({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelect,
  });

  /// Grouped rows from [buildPaletteRows].
  final List<PaletteRow> rows;

  /// Index into the SELECTABLE commands (not the flat rows).
  final int selectedIndex;

  /// Completes the chosen command.
  final void Function(CommandSpec spec) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    var cmdIndex = -1;

    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // `.command-palette`: rgba(20,20,35,.9) bg, glass border, top-rounded.
        color: const Color(0xE6141423),
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: const [
          // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final row in rows)
              if (row is PaletteHeader)
                _header(c, row.label)
              else if (row is PaletteCommand)
                Builder(builder: (_) {
                  cmdIndex++;
                  return _commandItem(
                    c,
                    row.spec,
                    selected: cmdIndex == selectedIndex,
                  );
                }),
          ],
        ),
      ),
    );
  }

  Widget _header(NymColors c, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 2),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            // `.command-category` — text-dim @0.7 opacity.
            color: c.textDim.withValues(alpha: 0.7),
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
      );

  Widget _commandItem(NymColors c, CommandSpec spec, {required bool selected}) {
    // `.command-name` shows the canonical name + collapsed aliases; the shared
    // row chrome (also used by the `?` bot palette) renders the rest.
    return commandItemRow(
      c,
      name: formatCommandDisplay(spec),
      desc: spec.desc,
      selected: selected,
      onTap: () => onSelect(spec),
    );
  }
}

/// The `#commandPalette` surface populated with the PUBLIC `?` Nymbot commands
/// (`showBotCommandPalette`, commands.js:436). Reuses the EXACT same chrome and
/// `.command-item` rows as [CommandPalette], but the bot list is FLAT (no
/// category headers — commands.js renders one `<div class="command-item">` per
/// entry) with the first row pre-selected. Completion inserts `"?<name> "`.
class BotCommandPalette extends StatelessWidget {
  const BotCommandPalette({
    super.key,
    required this.rows,
    required this.selectedIndex,
    required this.onSelect,
  });

  /// Filtered bot rows from [buildBotPaletteRows], in catalogue order.
  final List<BotPaletteCommand> rows;

  /// Index of the selected row.
  final int selectedIndex;

  /// Completes the chosen bot command (inserts `"?<name> "`).
  final void Function(BotPaletteCommand cmd) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      constraints: const BoxConstraints(maxHeight: 200),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        // `.command-palette`: rgba(20,20,35,.9) bg, glass border, top-rounded.
        color: const Color(0xE6141423),
        border: Border.all(color: c.glassBorder),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: const [
          // `--shadow-lg`: 0 8px 32px rgba(0,0,0,0.5).
          BoxShadow(color: Color(0x80000000), blurRadius: 32, offset: Offset(0, 8)),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i++)
              commandItemRow(
                c,
                name: rows[i].command,
                desc: rows[i].desc,
                selected: i == selectedIndex,
                onTap: () => onSelect(rows[i]),
              ),
          ],
        ),
      ),
    );
  }
}

/// A single `.command-item` row — the shared chrome used by BOTH the `/`
/// ([CommandPalette]) and `?` ([BotCommandPalette]) surfaces: a bold primary
/// `.command-name` on the left and a `.command-desc` (text-dim, brightening to
/// `--text` when selected/hovered) on the right. `:hover` → white/0.08,
/// `:active` → white/0.12, `.selected` → white/0.08.
Widget commandItemRow(
  NymColors c, {
  required String name,
  required String desc,
  required bool selected,
  required VoidCallback onTap,
}) {
  return Material(
    type: MaterialType.transparency,
    child: InkWell(
      onTap: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      hoverColor: Colors.white.withValues(alpha: 0.08),
      highlightColor: Colors.white.withValues(alpha: 0.12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white.withValues(alpha: 0.08) : null,
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                name,
                style: TextStyle(
                  color: c.primary,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                desc,
                style: TextStyle(
                  color: selected ? c.text : c.textDim,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Index navigation with wrap-around (navigateCommandPalette).
int wrapIndex(int index, int direction, int length) {
  if (length == 0) return -1;
  var next = index + direction;
  if (next < 0) next = length - 1;
  if (next >= length) next = 0;
  return next;
}
