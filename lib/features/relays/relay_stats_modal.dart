// relay_stats_modal.dart - `#relayStatsModal` port: the "Network Stats" modal
// (`openRelayStats` / `renderRelayStats`, app.js:7242-7680).
//
// Markup (index.html:1090-1146):
//   .modal > .modal-content.relay-stats-content
//     .modal-close (32px glass chip) · .modal-header "Network Stats"
//     .modal-body
//       .relay-stats-cards  → 5 cards: Connected / Avg Latency / Events /
//                              Data In / Data Out
//       .relay-stats-section "Throughput (events/sec)" → canvas graph
//       .relay-stats-section "Data transferred" → per-relay list
//       .relay-stats-low-data → Low-Data-Mode panel + nym-switch toggle
//
// Live data the app exposes today: the connected-relay COUNT
// (`appState.connectedRelays`, fed by `NostrService.onConnectionChanged`) and
// the per-relay connection status / relay list (via the optional
// `relayConnectionStatus` getter on the controller, see CROSS_FILE_NEEDS). Every
// counter the app does NOT yet track (latency, events, bytes in/out, throughput
// history) renders the PWA's real placeholder (`--` / `0` / `0 B` / empty graph)
// — NEVER a fabricated number. The Low-Data-Mode toggle is wired live to
// `settingsProvider.setLowDataMode` (mirrors `toggleLowDataModeFromStats`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';

class RelayStatsModal extends ConsumerWidget {
  const RelayStatsModal({super.key});

  /// Opens the Network Stats modal as a centered dialog (the PWA renders it as a
  /// `.modal` overlay, not a sheet). Wire this to the sidebar status-indicator
  /// (see CROSS_FILE_NEEDS).
  static Future<void> open(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierColor: const Color(0xB3000000), // .modal overlay rgba(0,0,0,0.7)
      builder: (_) => const RelayStatsModal(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.nym;
    // Real connected-relay count (NostrService.onConnectionChanged → appState).
    final connected =
        ref.watch(appStateProvider.select((s) => s.connectedRelays));
    final lowData =
        ref.watch(settingsProvider.select((s) => s.lowDataMode));

    // Per-relay status, if the controller exposes it (CROSS_FILE_NEEDS). Until
    // the getter lands this is null → the relay list shows the real empty state.
    final relayStatus = _readRelayStatus(ref);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          // .modal-content (radius 24, glass border, shadow + glow + 1px ring) +
          // .relay-stats-content (max-width 560, width 94%, padding 24).
          width: MediaQuery.of(context).size.width * 0.94,
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 720),
          decoration: BoxDecoration(
            color: c.bgSecondary,
            borderRadius: NymRadius.rxl,
            border: Border.all(color: c.glassBorder),
            boxShadow: [
              const BoxShadow(
                color: Color(0x80000000), // shadow-lg 0 8 32 black/0.5
                blurRadius: 32,
                offset: Offset(0, 8),
              ),
              BoxShadow(
                color: c.primary.withValues(alpha: 0.1), // shadow-glow
                blurRadius: 20,
              ),
              BoxShadow(
                color: Colors.white.withValues(alpha: 0.05), // 1px white ring
                spreadRadius: 1,
              ),
            ],
          ),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // .modal-header: 22px UPPERCASE primary + ls1.5 + bottom rule.
                    Container(
                      margin: const EdgeInsets.only(bottom: 24),
                      padding: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        border: Border(
                            bottom: BorderSide(color: c.glassBorder)),
                      ),
                      child: Text(
                        'NETWORK STATS',
                        style: TextStyle(
                          color: c.primary,
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    Flexible(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Cards(connected: connected),
                            const SizedBox(height: 14),
                            const _ThroughputSection(),
                            const SizedBox(height: 14),
                            _RelayListSection(relayStatus: relayStatus),
                            const SizedBox(height: 14),
                            _LowDataPanel(
                              enabled: lowData,
                              onToggle: (v) => ref
                                  .read(settingsProvider.notifier)
                                  .setLowDataMode(v),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // .modal-close — 32px circular glass chip, top-right (14,14).
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

  /// Reads the optional `relayConnectionStatus` getter off the controller
  /// (CROSS_FILE_NEEDS) without a compile-time dependency. Returns null when the
  /// getter is absent so the list falls back to its real empty state — never a
  /// fabricated relay row.
  Map<String, bool>? _readRelayStatus(WidgetRef ref) {
    try {
      final controller = ref.read(nostrControllerProvider);
      final dynamic dyn = controller;
      final result = dyn.relayConnectionStatus;
      if (result is Map) {
        return {
          for (final e in result.entries)
            if (e.key is String && e.value is bool)
              e.key as String: e.value as bool,
        };
      }
    } catch (_) {
      // Getter not present yet — render the empty state.
    }
    return null;
  }
}

// =============================================================================
// Summary cards (.relay-stats-cards / .relay-stat-card)
// =============================================================================

class _Cards extends StatelessWidget {
  const _Cards({required this.connected});
  final int connected;

  @override
  Widget build(BuildContext context) {
    // 5-up grid (.relay-stats-cards: grid 5, gap 6). Untracked metrics render
    // the PWA's literal placeholder (NEVER a fabricated value): latency `--`,
    // events `0`, data in/out `0 B`.
    return LayoutBuilder(builder: (context, cons) {
      const gap = 6.0;
      final cardW = (cons.maxWidth - gap * 4) / 5;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          _StatCard(width: cardW, value: '$connected', label: 'Connected'),
          _StatCard(width: cardW, value: '--', label: 'Avg Latency'),
          _StatCard(width: cardW, value: '0', label: 'Events'),
          _StatCard(width: cardW, value: '0 B', label: 'Data In'),
          _StatCard(width: cardW, value: '0 B', label: 'Data Out'),
        ],
      );
    });
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.width,
    required this.value,
    required this.label,
  });
  final double width;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
      decoration: BoxDecoration(
        // .relay-stat-card: white/0.03 fill, glass border, radius 12.
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        children: [
          // .relay-stat-value: mono 14, w700, primary.
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: c.primary,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          // .relay-stat-label: 9px UPPERCASE textDim, ls0.4.
          Text(
            label.toUpperCase(),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 9,
              color: c.textDim,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Section title (.relay-stats-section-title)
// =============================================================================

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: c.textDim,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

// =============================================================================
// Throughput graph (.relay-stats-graph-wrap > canvas)
// =============================================================================

class _ThroughputSection extends StatelessWidget {
  const _ThroughputSection();

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Throughput (events/sec)'),
        Container(
          // .relay-stats-graph-wrap: white/0.02 fill, glass border, radius 12,
          // padding 10. Canvas is 100px tall.
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          child: SizedBox(
            height: 100,
            width: double.infinity,
            // The app does not yet sample throughput history (no per-second
            // event counter in the relay layer — see CROSS_FILE_NEEDS). Render
            // the real empty graph: a flat baseline at y=0 with the `0/s` / `0`
            // scale labels the PWA draws when history is empty (max=1, data=[0]).
            child: CustomPaint(
              painter: _ThroughputPainter(
                line: c.primary,
                label: c.textDim,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws the empty throughput graph: a baseline line at the bottom (data=[0],
/// max=1) plus `0/s` (top-right) and `0` (bottom-right) scale labels — exactly
/// what `drawThroughputGraph([])` renders before any sample exists.
class _ThroughputPainter extends CustomPainter {
  _ThroughputPainter({
    required this.line,
    required this.label,
  });

  final Color line;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // data=[0], maxVal=1 → y = h - 2 for every point (flat baseline near floor).
    final y = h - 2;
    final strokePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    canvas.drawLine(Offset(0, y), Offset(w, y), strokePaint);

    // Scale labels (mono 9px, right-aligned), matching the canvas text.
    void drawLabel(String text, double anchorRight, double baselineY) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: label,
            fontSize: 9,
            fontFamily: 'monospace',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(anchorRight - tp.width, baselineY));
    }

    drawLabel('0/s', w - 2, 2);
    drawLabel('0', w - 2, h - 12);
  }

  @override
  bool shouldRepaint(covariant _ThroughputPainter old) =>
      old.line != line || old.label != label;
}

// =============================================================================
// Relay list (.relay-stats-relay-list / .relay-stats-row)
// =============================================================================

class _RelayListSection extends StatelessWidget {
  const _RelayListSection({required this.relayStatus});

  /// Per-relay url → open, when the controller exposes it; null otherwise.
  final Map<String, bool>? relayStatus;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // Build the relay rows from REAL per-relay status when available; otherwise
    // the list shows the PWA's real empty state ("No relays connected").
    final entries = <_RelayRowData>[];
    if (relayStatus != null) {
      for (final e in relayStatus!.entries) {
        if (RelayConfig.writeOnlyRelays.contains(e.key)) continue;
        entries.add(_RelayRowData(url: e.key, open: e.value));
      }
      // PWA sort: connected first, then by events (events all 0 here → stable).
      entries.sort((a, b) {
        if (a.open != b.open) return a.open ? -1 : 1;
        return 0;
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionTitle('Data transferred'),
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            // .relay-stats-relay-list: white/0.02 fill, glass border, radius 12.
            color: Colors.white.withValues(alpha: 0.02),
            borderRadius: NymRadius.rsm,
            border: Border.all(color: c.glassBorder),
          ),
          clipBehavior: Clip.antiAlias,
          child: entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'No relays connected',
                    style: TextStyle(color: c.textDim, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: entries.length,
                  itemBuilder: (ctx, i) => _RelayRow(
                    data: entries[i],
                    isLast: i == entries.length - 1,
                  ),
                ),
        ),
      ],
    );
  }
}

class _RelayRowData {
  const _RelayRowData({required this.url, required this.open});
  final String url;
  final bool open;
}

class _RelayRow extends StatelessWidget {
  const _RelayRow({required this.data, required this.isLast});
  final _RelayRowData data;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final shortUrl =
        data.url.replaceFirst('wss://', '').replaceFirst('ws://', '');
    return Container(
      // .relay-stats-row: padding 8/12, gap 10, bottom border white/0.04.
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.04))),
      ),
      child: Row(
        children: [
          // .relay-stats-dot: 6px, open=primary (glow) / closed=danger (glow).
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: data.open ? c.primary : c.danger,
              boxShadow: [
                BoxShadow(
                  color: (data.open ? c.primary : c.danger)
                      .withValues(alpha: data.open ? 0.5 : 0.4),
                  blurRadius: 6,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // .relay-stats-url: mono 11, textDim, ellipsized.
          Expanded(
            child: Text(
              shortUrl,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.textDim,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // .relay-stats-latency: mono 11, textDim, right-aligned, `--` (no
          // per-relay latency tracked yet — see CROSS_FILE_NEEDS).
          SizedBox(
            width: 45,
            child: Text(
              '--',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.textDim,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // .relay-stats-events: mono 11, textBright, right-aligned, `0 evt`
          // (no per-relay event counter tracked yet — see CROSS_FILE_NEEDS).
          SizedBox(
            width: 50,
            child: Text(
              '0 evt',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.textBright,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Low-Data-Mode panel (.relay-stats-low-data) + nym-switch toggle
// =============================================================================

class _LowDataPanel extends StatelessWidget {
  const _LowDataPanel({required this.enabled, required this.onToggle});
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      // .relay-stats-low-data: flex, gap 12, padding 12/14, white/0.03 fill,
      // glass border, radius 12.
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // .relay-stats-low-data-title: 13, w600, textBright.
                Text(
                  'Using too much data?',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: c.textBright,
                  ),
                ),
                const SizedBox(height: 2),
                // .relay-stats-low-data-hint: 11, textDim, line-height 1.4.
                Text(
                  'Enable Low Data Mode to limit relay connections to a small '
                  'core set and load geo relays only when entering channels.',
                  style: TextStyle(
                    fontSize: 11,
                    color: c.textDim,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _NymSwitch(value: enabled, onChanged: onToggle),
        ],
      ),
    );
  }
}

/// The `.nym-switch` toggle: 40×22 track, 16px thumb, off=white/0.12 +
/// textBright thumb / on=primary track + white thumb (thumb slides 18px).
class _NymSwitch extends StatelessWidget {
  const _NymSwitch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: NymMotion.transition,
        curve: NymMotion.curve,
        width: 40,
        height: 22,
        decoration: BoxDecoration(
          color: value ? c.primary : Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: value ? c.primary : c.glassBorder),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: NymMotion.transition,
              curve: NymMotion.curve,
              top: 2,
              left: value ? 18 : 2,
              child: Container(
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? Colors.white : c.textBright,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Close chip (.modal-close)
// =============================================================================

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
    final hovered = _hover;
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
            color: hovered
                ? c.danger.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            border: Border.all(
              color: hovered
                  ? c.danger.withValues(alpha: 0.3)
                  : c.glassBorder,
            ),
          ),
          child: Text(
            '✕',
            style: TextStyle(
              color: hovered ? c.danger : c.textDim,
              fontSize: 16,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
