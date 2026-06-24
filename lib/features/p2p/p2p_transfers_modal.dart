import 'package:flutter/material.dart';

import '../../core/theme/nym_colors.dart';
import '../../core/theme/nym_metrics.dart';
import 'p2p_models.dart';
import 'p2p_service.dart';

/// `#p2pTransfersModal` — lists seeding files + active/queued transfers with
/// progress (`openP2PTransfersModal`, p2p.js:732). Driven live by [P2PService]
/// (a [ChangeNotifier]); rebuilds as transfers progress.
class P2PTransfersModal extends StatelessWidget {
  const P2PTransfersModal({super.key, required this.service});

  final P2PService service;

  static Future<void> show(BuildContext context, P2PService service) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => P2PTransfersModal(service: service),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final seeding = service.seeding;
        final transfers = service.transfers;
        final empty = seeding.isEmpty && transfers.isEmpty;
        return Container(
          decoration: BoxDecoration(
            color: c.glassBg,
            border: Border(top: BorderSide(color: c.glassBorder)),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(NymRadius.lg)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text('P2P Transfers',
                        style: TextStyle(
                            color: c.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.close, color: c.textDim),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                if (empty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: Text('No active transfers',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: c.textDim)),
                  )
                else ...[
                  for (final entry in seeding.entries)
                    _SeedingRow(
                      offer: entry.value,
                      onStop: () => service.stopSeeding(entry.key),
                    ),
                  for (final t in transfers)
                    _TransferRow(
                      transfer: t,
                      onCancel: () => service.cancelTransfer(t.transferId),
                      onRetry: () => service.requestFile(t.offerId),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SeedingRow extends StatelessWidget {
  const _SeedingRow({required this.offer, required this.onStop});
  final FileOffer offer;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(offer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontWeight: FontWeight.w500)),
                const SizedBox(height: 2),
                Text(
                    '${formatFileSize(offer.size)} • Seeding${offer.isTorrent ? ' (Torrent)' : ' (P2P)'}',
                    style: TextStyle(color: c.textDim, fontSize: 12)),
              ],
            ),
          ),
          TextButton(
            onPressed: onStop,
            child: Text('Stop', style: TextStyle(color: c.danger)),
          ),
        ],
      ),
    );
  }
}

class _TransferRow extends StatelessWidget {
  const _TransferRow({
    required this.transfer,
    required this.onCancel,
    required this.onRetry,
  });
  final P2PTransfer transfer;
  final VoidCallback onCancel;
  final VoidCallback onRetry;

  /// The progress line: `pct% • speed/s` while transferring (matching the PWA's
  /// `updateFileOfferProgress`: `bytesReceived / elapsed`), else the status
  /// message coloured by state.
  String _progressLine(double pct) {
    final transferring = transfer.status == P2PStatus.transferring;
    if (transferring) {
      final n = transfer.isOutgoing ? transfer.bytesSent : transfer.bytesReceived;
      final elapsed =
          (DateTime.now().millisecondsSinceEpoch - transfer.startTime) / 1000.0;
      if (elapsed > 0 && n > 0) {
        final speed = (n / elapsed).round();
        return '${pct.toStringAsFixed(1)}% • ${formatFileSize(speed)}/s';
      }
    }
    final statusText = transfer.message ?? p2pStatusWire(transfer.status);
    return '${pct.toStringAsFixed(1)}% • $statusText';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.nym;
    final pct = transfer.progress;
    final statusColor = transfer.status == P2PStatus.error
        ? c.danger
        : transfer.status == P2PStatus.complete
            ? c.primary
            : c.textDim;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: NymRadius.rsm,
        border: Border.all(color: c.glassBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(transfer.offer.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: c.text, fontWeight: FontWeight.w500)),
              ),
              Text(formatFileSize(transfer.offer.size),
                  style: TextStyle(color: c.textDim, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(c.primary),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: Text(_progressLine(pct),
                    style: TextStyle(color: statusColor, fontSize: 12)),
              ),
              // Terminal affordances (PWA `updateTransferStatus`):
              //   complete → "Downloaded" label; error → "Retry" button
              //   (re-arms requestFile); otherwise → "Cancel".
              if (transfer.status == P2PStatus.complete)
                Text('Downloaded',
                    style: TextStyle(color: c.primary, fontSize: 12))
              else if (transfer.status == P2PStatus.error)
                GestureDetector(
                  onTap: onRetry,
                  child: Text('Retry',
                      style: TextStyle(
                          color: c.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                )
              else
                GestureDetector(
                  onTap: onCancel,
                  child: Text('Cancel',
                      style: TextStyle(color: c.danger, fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
