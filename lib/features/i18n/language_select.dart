import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/settings_provider.dart';
import '../translate/translate_languages.dart';
import 'app_strings_catalog.dart';
import 'i18n.dart';
import 'localization_service.dart';

/// A selectable UI-language option: its stored code (empty ⇒ English source)
/// and its English display name.
class UiLanguageOption {
  const UiLanguageOption(this.code, this.name);
  final String code;
  final String name;
}

/// The full UI-language menu: English pinned first (stored as `''` so it maps
/// to the no-translate source path), then every language the message
/// translator supports, alphabetically. Reuses [sortedTranslateLanguages] so
/// the app-language list stays in lockstep with the message-translation list.
final List<UiLanguageOption> kUiLanguageOptions = [
  const UiLanguageOption('', 'English'),
  ...sortedTranslateLanguages()
      .where((e) => e.key != 'en')
      .map((e) => UiLanguageOption(e.key, e.value)),
];

/// The display name for a stored UI-language [code] (empty/`en` ⇒ English).
String uiLanguageName(String code) {
  if (code.isEmpty || code == 'en') return 'English';
  return languageName(code);
}

/// Applies [code] as the app UI language: persists the setting (which drives
/// `LocalizationService.setLanguage` via the root listener) then awaits a bulk
/// pre-translation of the strings already on screen so the switch is complete
/// before the caller proceeds. Shows a small blocking progress dialog while the
/// pass runs (skipped instantly for English). Safe to call from anywhere with a
/// [ref].
Future<void> applyUiLanguage(
  BuildContext context,
  WidgetRef ref,
  String code,
) async {
  ref.read(settingsProvider.notifier).setUiLanguage(code);
  // Apply immediately rather than waiting on the root's settings listener (its
  // callback fires asynchronously); setLanguage is idempotent, so the listener
  // re-invoking it with the same code is a harmless no-op.
  final svc = LocalizationService.instance;
  svc.setLanguage(code);
  if (!svc.isActive) return; // English: nothing to pre-translate.

  final progress = ValueNotifier<double>(0);
  final navigator = Navigator.of(context, rootNavigator: true);
  var dialogOpen = true;
  // A lightweight, non-dismissible progress dialog.
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _TranslatingDialog(progress: progress),
  ).then((_) => dialogOpen = false));

  await svc.pretranslate(onProgress: (done, total) {
    progress.value = total == 0 ? 1 : done / total;
  });

  if (dialogOpen) navigator.pop();
  progress.dispose();

  // Give the screen shown right after the picker (the welcome/setup modal, then
  // the shell) a head start: its on-demand `tr()` misses queue and translate
  // first, so it localizes promptly. Then sweep the REST of the app's UI in the
  // background so every later screen is pre-populated in the cache — no
  // on-demand flashes as the user navigates. Non-blocking; runs in chunks.
  unawaited(Future<void>.delayed(
    const Duration(milliseconds: 2500),
    () => svc.sweep(kAppStringsCatalog),
  ));
}

/// First-run, full-screen language chooser shown at the very start of
/// onboarding (before the guided tutorial). Picking a language localizes the
/// app going forward and persists the choice; [onComplete] then advances to the
/// tutorial. English is offered first so the default path is one tap.
class LanguageSelectScreen extends ConsumerWidget {
  const LanguageSelectScreen({super.key, required this.onComplete});

  /// Called once a language has been chosen and applied.
  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    // English by design — the user hasn't chosen a language yet,
                    // so this welcome greeting stays in the source language.
                    'Choose your language',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.text,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'You can change this anytime in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: c.textDim, fontSize: 13),
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: LanguagePickerList(
                      selectedCode: ref.watch(
                          settingsProvider.select((s) => s.uiLanguage)),
                      onSelected: (code) async {
                        await applyUiLanguage(context, ref, code);
                        onComplete();
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A searchable, scrollable list of [kUiLanguageOptions] with the active one
/// checked. Reused by the onboarding screen and the Settings language dialog.
class LanguagePickerList extends StatefulWidget {
  const LanguagePickerList({
    super.key,
    required this.selectedCode,
    required this.onSelected,
  });

  final String selectedCode;
  final ValueChanged<String> onSelected;

  @override
  State<LanguagePickerList> createState() => _LanguagePickerListState();
}

class _LanguagePickerListState extends State<LanguagePickerList> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final q = _query.trim().toLowerCase();
    final items = q.isEmpty
        ? kUiLanguageOptions
        : kUiLanguageOptions
            .where((o) => o.name.toLowerCase().contains(q))
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Search box.
        Container(
          decoration: BoxDecoration(
            color: c.bgTertiary,
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Icon(Icons.search, size: 18, color: c.textDim),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  style: TextStyle(color: c.text, fontSize: 14),
                  cursorColor: c.primary,
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: tr('Search languages'),
                    hintStyle: TextStyle(color: c.textDim, fontSize: 14),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: items.length,
            itemBuilder: (_, i) {
              final o = items[i];
              final selected = o.code == widget.selectedCode ||
                  (o.code.isEmpty && widget.selectedCode == 'en');
              return _LanguageRow(
                name: o.name,
                selected: selected,
                onTap: () => widget.onSelected(o.code),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return InkWell(
      onTap: onTap,
      borderRadius: NymRadius.rsm,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected ? c.primary.withValues(alpha: 0.12) : null,
          borderRadius: NymRadius.rsm,
          border: Border.all(
            color: selected ? c.primary : c.glassBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: c.text,
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 18, color: c.primary),
          ],
        ),
      ),
    );
  }
}

/// Opens the language chooser as a modal dialog (used from Settings). Applies
/// the selection (with the translating-progress dialog) on tap, then closes.
Future<void> showLanguagePickerDialog(BuildContext context, WidgetRef ref) {
  final c = context.nym;
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      backgroundColor: c.bgSecondary,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rlg,
        side: BorderSide(color: c.glassBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Language'),
                      style: TextStyle(
                        color: c.text,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: c.textDim),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Consumer(
                  builder: (context, ref, _) => LanguagePickerList(
                    selectedCode:
                        ref.watch(settingsProvider.select((s) => s.uiLanguage)),
                    onSelected: (code) async {
                      Navigator.of(dialogContext).pop();
                      await applyUiLanguage(context, ref, code);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Non-dismissible "Translating…" progress dialog shown while a language switch
/// pre-translates the on-screen strings.
class _TranslatingDialog extends StatelessWidget {
  const _TranslatingDialog({required this.progress});
  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Dialog(
      backgroundColor: c.bgSecondary,
      shape: RoundedRectangleBorder(
        borderRadius: NymRadius.rlg,
        side: BorderSide(color: c.glassBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (_, v, __) => SizedBox(
                width: 40,
                height: 40,
                child: CircularProgressIndicator(
                  value: v > 0 && v < 1 ? v : null,
                  strokeWidth: 3,
                  color: c.primary,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr('Translating…'),
              style: TextStyle(color: c.text, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }
}
