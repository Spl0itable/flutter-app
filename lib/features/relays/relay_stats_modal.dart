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
// Live data: the connected-relay COUNT (`appState.connectedRelays`, fed by
// `NostrService.onConnectionChanged`), the per-relay connection status
// (`NostrController.relayConnectionStatus`), and the real relay-traffic
// counters (`NostrController.relayStats` → `RelayStats`: avg latency, total
// events, bytes in/out, the throughput-history graph, and per-relay
// events/latency rows). A 1s `Timer.periodic` re-reads a `RelayStats.snapshot`
// each tick so every metric refreshes live (mirrors the PWA `_rsRenderInterval`
// 1s poll). When `relayStats` is null (pre-boot) OR a specific metric is absent,
// the PWA's real placeholder renders (`--` / `0` / `0 B` / flat graph) — NEVER a
// fabricated number. The Low-Data-Mode toggle is wired live to
// `settingsProvider.setLowDataMode` (mirrors `toggleLowDataModeFromStats`).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/relays.dart';
import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import '../../services/relay/relay_stats.dart';
import '../../state/app_state.dart';
import '../../state/nostr_controller.dart';
import '../../state/settings_provider.dart';

class RelayStatsModal extends ConsumerStatefulWidget {
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
  ConsumerState<RelayStatsModal> createState() => _RelayStatsModalState();
}

class _RelayStatsModalState extends ConsumerState<RelayStatsModal> {
  // Mirrors the PWA `_rsRenderInterval` 1s poll (app.js:7339): re-read the live
  // counters every second so the cards/graph/rows refresh while the modal is up.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    // Real connected-relay count (NostrService.onConnectionChanged → appState).
    final connected =
        ref.watch(appStateProvider.select((s) => s.connectedRelays));
    final lowData =
        ref.watch(settingsProvider.select((s) => s.lowDataMode));

    // Live relay traffic counters — typed getter on the controller, null before
    // boot. Read a stable snapshot so a per-second source mutation can't tear a
    // frame mid-render (mirrors the PWA reading `nym.relayStats` each tick).
    final stats = ref.read(nostrControllerProvider).relayStats?.snapshot();

    // Per-relay connection status (url → connected), typed getter; empty before
    // boot → the relay list shows the real "No relays connected" empty state.
    final relayStatus = ref.read(nostrControllerProvider).relayConnectionStatus;

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
                            _Cards(connected: connected, stats: stats),
                            const SizedBox(height: 14),
                            _ThroughputSection(
                              history: stats?.throughputHistory ?? const [],
                            ),
                            const SizedBox(height: 14),
                            _RelayListSection(
                              relayStatus: relayStatus,
                              stats: stats,
                            ),
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
}

// =============================================================================
// Summary cards (.relay-stats-cards / .relay-stat-card)
// =============================================================================

class _Cards extends StatelessWidget {
  const _Cards({required this.connected, required this.stats});
  final int connected;

  /// Live relay counters, or null before boot. When null every untracked metric
  /// renders the PWA's literal placeholder (NEVER a fabricated value): latency
  /// `--`, events `0`, data in/out `0 B`.
  final RelayStats? stats;

  @override
  Widget build(BuildContext context) {
    // Real values when [stats] is available; PWA placeholders otherwise.
    // Avg Latency: `avgLat !== null ? avgLat + 'ms' : '--'` (app.js:7391).
    final latency = stats?.averageLatencyMs != null
        ? '${stats!.averageLatencyMs}ms'
        : '--';
    // Events: k-abbreviated total (app.js:7392).
    final events =
        stats != null ? _abbreviateCount(stats!.totalEvents) : '0';
    // Data In / Out: formatBytes (app.js:7393-7394).
    final dataIn = stats != null ? formatBytes(stats!.bytesReceived) : '0 B';
    final dataOut = stats != null ? formatBytes(stats!.bytesSent) : '0 B';

    // 5-up grid (.relay-stats-cards: grid 5, gap 6).
    return LayoutBuilder(builder: (context, cons) {
      const gap = 6.0;
      final cardW = (cons.maxWidth - gap * 4) / 5;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          _StatCard(width: cardW, value: '$connected', label: 'Connected'),
          _StatCard(width: cardW, value: latency, label: 'Avg Latency'),
          _StatCard(width: cardW, value: events, label: 'Events'),
          _StatCard(width: cardW, value: dataIn, label: 'Data In'),
          _StatCard(width: cardW, value: dataOut, label: 'Data Out'),
        ],
      );
    });
  }
}

/// k-abbreviated event count, mirroring the PWA Events card
/// (`s.totalEvents > 9999 ? (s.totalEvents / 1000).toFixed(1) + 'k' :
/// s.totalEvents`, app.js:7392): only past 9999 does it switch to `X.Xk`.
String _abbreviateCount(int n) =>
    n > 9999 ? '${(n / 1000).toStringAsFixed(1)}k' : '$n';

/// Human-readable byte size, a 1:1 port of the PWA `formatBytes` (app.js:7347):
/// `< 1024` → `N B`; `< 1MiB` → `X.X KB`; `< 1GiB` → `X.X MB`; else `X.XX GB`.
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1048576) return '${(b / 1024).toStringAsFixed(1)} KB';
  if (b < 1073741824) return '${(b / 1048576).toStringAsFixed(1)} MB';
  return '${(b / 1073741824).toStringAsFixed(2)} GB';
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
  const _ThroughputSection({required this.history});

  /// Last ≤60 per-second event counts (oldest→newest). Empty before any sample
  /// → the flat-baseline placeholder.
  final List<int> history;

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
            // Real polyline once samples exist; the empty list renders the flat
            // baseline + `0/s`/`0` labels the PWA draws for `data=[0]`, max=1.
            child: CustomPaint(
              painter: _ThroughputPainter(
                history: history,
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

/// Port of the PWA `drawThroughputGraph` (app.js:7424): plots the last ≤60
/// per-second event counts as a fill + 1.5px polyline (newest at the right),
/// scaled to `max(1, …history)`, with `<max>/s` (top-right) and `0`
/// (bottom-right) mono-9px labels. An empty list collapses to `data=[0]`,
/// max=1 → the flat baseline the PWA draws before any sample exists.
class _ThroughputPainter extends CustomPainter {
  _ThroughputPainter({
    required this.history,
    required this.line,
    required this.label,
  });

  final List<int> history;
  final Color line;
  final Color label;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // data = history.length > 0 ? history : [0] (app.js:7442).
    final data = history.isNotEmpty ? history : const [0];
    final maxVal = math.max(1, data.reduce(math.max));
    const points = 60;
    final stepX = w / (points - 1);
    // Right-align: the freshest sample sits at index `points - 1` (app.js:7456).
    final startIdx = math.max(0, points - data.length);

    double xAt(int i) => (startIdx + i) * stepX;
    double yAt(int i) => h - (data[i] / maxVal) * (h - 4) - 2;

    // Fill gradient under the line (primary 0.25 → 0.02 top→bottom).
    final fillPath = Path()..moveTo(xAt(0), h);
    for (var i = 0; i < data.length; i++) {
      fillPath.lineTo(xAt(i), yAt(i));
    }
    fillPath.lineTo(xAt(data.length - 1), h);
    fillPath.close();
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          line.withValues(alpha: 0.25),
          line.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawPath(fillPath, fillPaint);

    // Polyline (primary stroke 1.5, round join).
    final linePath = Path()..moveTo(xAt(0), yAt(0));
    for (var i = 1; i < data.length; i++) {
      linePath.lineTo(xAt(i), yAt(i));
    }
    final strokePaint = Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(linePath, strokePaint);

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

    drawLabel('$maxVal/s', w - 2, 2);
    drawLabel('0', w - 2, h - 12);
  }

  @override
  bool shouldRepaint(covariant _ThroughputPainter old) =>
      old.line != line ||
      old.label != label ||
      !_sameHistory(old.history, history);

  static bool _sameHistory(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

// =============================================================================
// Relay list (.relay-stats-relay-list / .relay-stats-row)
// =============================================================================

class _RelayListSection extends StatelessWidget {
  const _RelayListSection({required this.relayStatus, required this.stats});

  /// Per-relay url → open (empty before boot → real empty state).
  final Map<String, bool> relayStatus;

  /// Live counters for the per-relay events/latency columns; null before boot.
  final RelayStats? stats;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;

    // Build the relay rows from REAL per-relay status; the empty status map
    // leaves the list showing the PWA's real empty state ("No relays
    // connected"). Each row carries its real `eventsPerRelay`/`latencyPerRelay`
    // value (absent → 0 events / `--` latency — never a fabricated number).
    final entries = <_RelayRowData>[];
    for (final e in relayStatus.entries) {
      if (RelayConfig.writeOnlyRelays.contains(e.key)) continue;
      entries.add(_RelayRowData(
        url: e.key,
        open: e.value,
        events: stats?.eventsPerRelay[e.key] ?? 0,
        latency: stats?.latencyPerRelay[e.key],
      ));
    }
    // PWA sort: connected first, then by events DESC (app.js:7592-7595).
    entries.sort((a, b) {
      if (a.open != b.open) return a.open ? -1 : 1;
      return b.events - a.events;
    });

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
  const _RelayRowData({
    required this.url,
    required this.open,
    required this.events,
    required this.latency,
  });
  final String url;
  final bool open;

  /// Unique inbound events from this relay (`eventsPerRelay[url] ?? 0`).
  final int events;

  /// Last measured latency in ms, or null → render `--` (`latencyPerRelay[url]`).
  final int? latency;
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
          // .relay-stats-latency: mono 11, textDim, right-aligned. Real
          // `<ms>ms`, or `--` when no latency has been measured (app.js:7660).
          SizedBox(
            width: 45,
            child: Text(
              data.latency != null ? '${data.latency}ms' : '--',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 11,
                color: c.textDim,
              ),
            ),
          ),
          const SizedBox(width: 10),
          // .relay-stats-events: mono 11, textBright, right-aligned. Real
          // `<n> evt` per-relay event count (app.js:7652).
          SizedBox(
            width: 50,
            child: Text(
              '${data.events} evt',
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
