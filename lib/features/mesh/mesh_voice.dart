// Push-to-talk voice over the Bluetooth mesh.
//
// There is no IP connectivity offline, so WebRTC calls can't traverse the mesh;
// instead this is half-duplex walkie-talkie voice, matching bitchat's live PTT.
// The mic is captured as an 8 kHz mono PCM16 stream, companded to 8-bit µ-law
// (pure Dart, ~8 KB/s — inside BLE's budget), and sent as ephemeral voiceFrame
// packets (broadcast for a channel, directed for a DM). Inbound frames are
// decoded and fed to a low-latency streaming PCM player.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

import '../../services/mesh/mesh_events.dart';
import '../../services/mesh/protocol/mulaw.dart';
import '../../state/app_state.dart';
import 'mesh_bridge.dart';

/// The audio parameters for mesh PTT (must match on both ends).
const int kVoiceSampleRate = 8000;

/// A live PTT voice session bound to one conversation [view]. Owned by the PTT
/// overlay widget: constructed on open, disposed on close. While open it plays
/// inbound frames for this conversation; [startTalk]/[stopTalk] transmit.
class MeshVoiceSession {
  MeshVoiceSession({required this.bridge, required this.view});

  final MeshBridge bridge;
  final ChatView view;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  StreamSubscription<MeshVoiceFrameEvent>? _voiceSub;
  int _seq = 0;

  bool _playerReady = false;
  bool _disposed = false;

  /// Decoded PCM16 samples awaiting playback (jitter buffer).
  final List<int> _playBuf = [];
  Timer? _speakerClear;

  /// True while we're transmitting (hold-to-talk pressed).
  final ValueNotifier<bool> transmitting = ValueNotifier(false);

  /// The nym of the peer currently heard speaking (null when silent).
  final ValueNotifier<String?> speaker = ValueNotifier(null);

  /// True when a live PTT permission/hardware error occurred.
  final ValueNotifier<String?> error = ValueNotifier(null);

  void init() {
    _voiceSub = bridge.onVoiceFrame.listen(_onFrame);
  }

  Future<void> startTalk() async {
    if (transmitting.value || _disposed) return;
    try {
      if (!await _recorder.hasPermission()) {
        error.value = 'Microphone permission needed';
        return;
      }
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: kVoiceSampleRate,
        numChannels: 1,
      ));
      transmitting.value = true;
      _micSub = stream.listen((pcm) {
        if (_disposed || pcm.isEmpty) return;
        final mulaw = MuLaw.encode(pcm);
        bridge.sendVoiceFrame(view, mulaw, _seq++ & 0xFFFF);
      });
    } catch (e) {
      error.value = '$e';
      transmitting.value = false;
    }
  }

  Future<void> stopTalk() async {
    transmitting.value = false;
    await _micSub?.cancel();
    _micSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
  }

  // ---- Inbound playback ----------------------------------------------------

  void _onFrame(MeshVoiceFrameEvent e) {
    if (_disposed || !_matchesView(e)) return;
    unawaited(_ensurePlayer());
    final pcm = MuLaw.decode(e.mulaw);
    final bd = ByteData.sublistView(pcm);
    for (var i = 0; i + 1 < pcm.length; i += 2) {
      _playBuf.add(bd.getInt16(i, Endian.little));
    }
    // Bound the jitter buffer so a backlog can't grow unbounded.
    const maxBuffered = kVoiceSampleRate * 2; // ~2s
    if (_playBuf.length > maxBuffered) {
      _playBuf.removeRange(0, _playBuf.length - maxBuffered);
    }
    speaker.value = bridge.nymForPeerId(e.senderPeerID);
    _speakerClear?.cancel();
    _speakerClear = Timer(const Duration(milliseconds: 600), () {
      speaker.value = null;
    });
  }

  bool _matchesView(MeshVoiceFrameEvent e) {
    if (view.kind == ViewKind.channel) {
      if (e.isDirect) return false;
      final ch = (e.channel == null || e.channel!.isEmpty)
          ? kMeshNearbyChannel
          : (e.channel!.startsWith('#')
              ? e.channel!.substring(1)
              : e.channel!);
      return ch.toLowerCase() == view.id.toLowerCase();
    }
    if (view.kind == ViewKind.pm) {
      return e.isDirect &&
          bridge.pubkeyForPeerId(e.senderPeerID).toLowerCase() ==
              view.id.toLowerCase();
    }
    return false;
  }

  Future<void> _ensurePlayer() async {
    if (_playerReady || _disposed) return;
    _playerReady = true;
    try {
      await FlutterPcmSound.setup(
          sampleRate: kVoiceSampleRate, channelCount: 1);
      await FlutterPcmSound.setFeedThreshold(kVoiceSampleRate ~/ 10);
      FlutterPcmSound.setFeedCallback(_onFeed);
      // Prime playback; the feed callback drives it thereafter.
      _onFeed(0);
    } catch (e) {
      error.value = '$e';
      _playerReady = false;
    }
  }

  void _onFeed(int remaining) {
    if (_disposed) return;
    // Feed ~100ms per callback; pad with silence when the buffer underruns so
    // playback keeps ticking (and the callback keeps firing).
    const frame = kVoiceSampleRate ~/ 10;
    final take = _playBuf.length >= frame ? frame : _playBuf.length;
    final List<int> chunk;
    if (take > 0) {
      chunk = _playBuf.sublist(0, take);
      _playBuf.removeRange(0, take);
      if (take < frame) chunk.addAll(List<int>.filled(frame - take, 0));
    } else {
      chunk = List<int>.filled(frame, 0);
    }
    FlutterPcmSound.feed(PcmArrayInt16.fromList(chunk));
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopTalk();
    await _voiceSub?.cancel();
    _speakerClear?.cancel();
    _recorder.dispose();
    if (_playerReady) {
      FlutterPcmSound.setFeedCallback(null);
      try {
        await FlutterPcmSound.release();
      } catch (_) {}
    }
    transmitting.dispose();
    speaker.dispose();
    error.dispose();
  }
}
