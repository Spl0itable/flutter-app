import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/nym_colors.dart';
import '../../models/channel.dart';
import '../../services/api/api_client.dart';
import '../../state/app_state.dart';
import '../../state/settings_provider.dart';
import 'geo_map_painter.dart';
import 'geo_projection.dart';
import 'geohash_channel.dart';
import 'topojson.dart';

/// Breakpoint below which the explorer collapses to its phone layout (the PWA's
/// `@media (max-width: 768px)` rules: info panel becomes a bottom bar, the window
/// button group collapses into a `<select>`).
const double kGlobeNarrowBreakpoint = 768;

/// Path to the bundled world map TopoJSON (`countries-110m.json`).
const String kWorldTopoAsset = 'assets/data/countries-110m.json';

/// Active-window options in hours (matches the PWA's `windowOptions`).
const List<int> kActiveWindowOptions = [1, 3, 6, 12, 24];

/// Top-level worker entry for [compute]: decode the world TopoJSON off the UI
/// thread. Defined at top level so it can run in an isolate.
List<GeoFeature> decodeWorldFeaturesIsolate(String jsonString) =>
    decodeWorldTopoJson(jsonString);

/// The `#geohashExplorerModal` screen — a self-contained equirectangular world
/// map for browsing geohash channels. Pan via drag, zoom via scroll/pinch, an
/// active-window selector, controls (zoom, reset, heat, day/night, grid), a
/// legend, and a channel/cell info panel with a Join button.
///
/// Selecting (Join) a geohash pops this route with the lowercase geohash string
/// so the caller can open that channel: `Navigator.push<String>(...)`.
class GeohashExplorer extends ConsumerStatefulWidget {
  const GeohashExplorer({super.key});

  /// A non-opaque modal route (F11): the app stays visible behind a
  /// `rgba(0,0,0,0.4)` scrim while the explorer card floats over it, matching
  /// the PWA's centered `.geohash-explorer-modal` overlay (instead of a full
  /// opaque page transition). Resolves to the chosen lowercase geohash (or null
  /// if dismissed), so callers keep using `Navigator.push<String>(...)`.
  static Route<String> route() {
    return PageRouteBuilder<String>(
      opaque: false,
      barrierColor: const Color(0x66000000), // rgba(0,0,0,0.4)
      barrierDismissible: false,
      transitionDuration: const Duration(milliseconds: 180),
      pageBuilder: (_, __, ___) => const GeohashExplorer(),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    );
  }

  @override
  ConsumerState<GeohashExplorer> createState() => _GeohashExplorerState();
}

class _GeohashExplorerState extends ConsumerState<GeohashExplorer> {
  GeoView _view = const GeoView();
  List<GeoFeature> _features = const [];
  Size _lastSize = Size.zero;

  bool _heatmap = false;
  bool _daynight = false;
  bool _grid = false;
  int _activeWindowHours = 24;

  String? _hoveredGeohash;
  bool _dragging = false;

  /// The currently selected channel/cell (drives the info panel + Join).
  GeohashChannelPoint? _selected;

  /// Reverse-geocoded "city, country" for [_selected]; seeded with the PWA's
  /// literal `Loading location...` until the geocode resolves.
  String _locationInfo = 'Loading location...';

  /// Monotonic token so a stale geocode response can't overwrite a newer
  /// selection's Location row (mirrors re-selecting in the PWA).
  int _geocodeToken = 0;

  // Drag state.
  GeoView? _dragStartView;

  // --- Heatmap precompute (F1) ---------------------------------------------
  // The PWA's `drawHeatmap` accumulates blobs into a half-res buffer then
  // remaps per-pixel alpha through the palette; that can't run inside paint, so
  // we build a `ui.Image` off the paint pass and hand it to the painter.
  ui.Image? _heatImage;
  HeatmapInput? _heatInputForImage; // the input that produced _heatImage
  HeatmapInput? _heatInFlight; // the input currently being built
  Timer? _heatDebounce;

  final ApiClient _api = ApiClient();

  // Periodic refresh (heatmap activity / day-night), like the PWA's intervals.
  Timer? _refreshTimer;
  final ValueNotifier<int> _ticker = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _loadFeatures();
    // Refresh activity counts (30s) and day/night (60s); a single 30s tick that
    // rebuilds is sufficient for our read-only store.
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _ticker.value++;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _heatDebounce?.cancel();
    _heatImage?.dispose();
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _loadFeatures() async {
    try {
      final jsonStr = await rootBundle.loadString(kWorldTopoAsset);
      // Decode off the UI thread.
      final feats = await compute(decodeWorldFeaturesIsolate, jsonStr);
      if (!mounted) return;
      setState(() => _features = feats);
    } catch (_) {
      // Leave the map empty (ocean + graticule) if decoding fails.
    }
  }

  List<GeohashChannelPoint> _channels() {
    final state = ref.read(appStateProvider);
    return buildGeohashChannels(state, windowHours: _activeWindowHours);
  }

  /// The user's location for the map marker / distance row, but only when the
  /// PWA would show it: `settings.sortByProximity && userLocation` (matches
  /// `showYourLocation` in geohash-globe.js:236).
  ({double lat, double lng})? _userLocation() {
    final sortByProximity =
        ref.read(settingsProvider).sortByProximity;
    final loc = ref.read(userLocationProvider);
    if (!sortByProximity || loc == null) return null;
    return (lat: loc.lat, lng: loc.lng);
  }

  void _setView(GeoView v, Size size) {
    setState(() => _view = v.clamped(size));
  }

  // --- Heatmap image lifecycle (F1) ----------------------------------------

  /// (Re)builds the heatmap [ui.Image] when [heatmap] is on and the inputs
  /// (view/size/activity) changed, debounced like the PWA's throttled redraw.
  /// No-op (and clears any cached image) when heatmap mode is off.
  void _maybeRebuildHeat(Size size, List<GeohashChannelPoint> channels) {
    if (!_heatmap) {
      if (_heatImage != null || _heatInputForImage != null) {
        _heatImage?.dispose();
        _heatImage = null;
        _heatInputForImage = null;
      }
      _heatDebounce?.cancel();
      _heatInFlight = null;
      return;
    }
    final input = HeatmapInput(
      view: _view,
      size: size,
      points: [
        for (final c in channels)
          (lng: c.lng, lat: c.lat, messages: c.messages),
      ],
    );
    // Already current or already building this exact input — nothing to do.
    if (input == _heatInputForImage || input == _heatInFlight) return;
    _heatDebounce?.cancel();
    _heatDebounce = Timer(const Duration(milliseconds: 60), () {
      if (!mounted || !_heatmap) return;
      _heatInFlight = input;
      buildHeatmapImage(input).then((img) {
        if (!mounted || !_heatmap) {
          img?.dispose();
          return;
        }
        // Drop the result if the inputs moved on while we were building.
        if (_heatInFlight != input) {
          img?.dispose();
          return;
        }
        setState(() {
          _heatImage?.dispose();
          _heatImage = img;
          _heatInputForImage = input;
          _heatInFlight = null;
        });
      });
    });
  }

  // --- Gesture handling -----------------------------------------------------

  GeohashChannelPoint? _channelAt(Offset local, Size size) {
    const hitR = 10.0;
    GeohashChannelPoint? nearest;
    var best = double.infinity;
    for (final ch in _channels()) {
      final p = _view.project(ch.lng, ch.lat, size);
      final d = (p - local).distance;
      if (d < hitR && d < best) {
        best = d;
        nearest = ch;
      }
    }
    return nearest;
  }

  void _onTapUp(TapUpDetails d, Size size) {
    final local = d.localPosition;
    final ch = _channelAt(local, size);
    if (ch != null) {
      // PWA (`geohash-globe.js` onPointerUp): tapping a channel dot calls
      // `selectGeohashChannel(ch)` only — it selects/joins without re-framing
      // the camera. Only a grid-cell tap (`_selectGeohashCell`) zooms to bounds.
      _selectChannel(ch);
      return;
    }
    if (_grid) {
      final u = _view.unproject(local.dx, local.dy, size);
      if (u.lat < -90 || u.lat > 90 || u.lng < -180 || u.lng > 180) return;
      final precision = computeGridPrecision(_view, size);
      final gh = encodeGeohash(u.lat, u.lng, precision: precision);
      _selectCell(gh, size);
    }
  }

  /// Selects a channel/cell for the info panel and (re)starts a reverse-geocode
  /// for its Location row. Mirrors `selectGeohashChannel` (channels.js:345): the
  /// Location row shows `Loading location...` until the geocode resolves.
  void _selectChannel(GeohashChannelPoint point) {
    final token = ++_geocodeToken;
    setState(() {
      _selected = point;
      _hoveredGeohash = point.geohash;
      _locationInfo = 'Loading location...';
    });
    _fetchLocation(point.lat, point.lng, token);
  }

  /// Reverse-geocodes (lat,lng) → "city, country" (`fetchGeocode(lat,lng,10)`),
  /// updating the Location row only if [token] is still the active selection.
  Future<void> _fetchLocation(double lat, double lng, int token) async {
    String result;
    try {
      final data = await _api.geocode(lat, lng, zoom: 10);
      final addr = (data['address'] as Map?) ?? const {};
      String s(Object? v) => v is String ? v : '';
      final city = [
        s(addr['city']),
        s(addr['town']),
        s(addr['village']),
        s(addr['county']),
      ].firstWhere((x) => x.isNotEmpty, orElse: () => '');
      final country = s(addr['country']);
      result = [city, country].where((x) => x.isNotEmpty).join(', ');
      if (result.isEmpty) result = 'Unknown location';
    } catch (_) {
      result = 'Unknown';
    }
    if (!mounted || token != _geocodeToken) return;
    setState(() => _locationInfo = result);
  }

  /// Mirrors `_selectGeohashCell`: zoom to the cell, reuse an existing channel
  /// entry if present, else synthesize one.
  void _selectCell(String geohash, Size size) {
    final gh = geohash.toLowerCase();
    final bounds = geohashBounds(gh);
    if (bounds == null) return;
    final existing = _channels().where((c) => c.geohash == gh);
    final point = existing.isNotEmpty
        ? existing.first
        : GeohashChannelPoint(
            geohash: gh,
            lat: (bounds.latLo + bounds.latHi) / 2,
            lng: (bounds.lngLo + bounds.lngHi) / 2,
            messages: 0,
            isJoined: false,
          );
    _selectChannel(point);
    _view = _view.fitBounds(bounds, size).clamped(size);
  }

  void _resetView(Size size) {
    setState(() {
      _view = const GeoView().clamped(size);
      _heatmap = false;
      _daynight = false;
      _grid = false;
      _selected = null;
      _hoveredGeohash = null;
      _locationInfo = 'Loading location...';
      _activeWindowHours = 24;
    });
  }

  void _join(String geohash) {
    Navigator.of(context).pop(geohash.toLowerCase());
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final nym = context.nym;
    final style = GeoMapStyle.resolve(
      isLight: nym.isLight,
      primary: nym.primary,
      warning: nym.warning,
    );

    // F11 — the PWA explorer is a centered overlay (scrim rgba(0,0,0,0.4)) that
    // floats over the still-visible app, with a 90%×90% (max 1200×800) card
    // carrying `shadow-lg` + `shadow-glow`. When pushed via [route] the route is
    // non-opaque (barrier supplies the scrim), so the scaffold itself must be
    // transparent to let the app show through; under a plain opaque route we
    // keep the scrim on the scaffold so there's no black void behind the card.
    final opaqueRoute = ModalRoute.of(context)?.opaque ?? true;
    return Scaffold(
      backgroundColor:
          opaqueRoute ? const Color(0x66000000) : Colors.transparent,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200, maxHeight: 800),
            child: FractionallySizedBox(
              widthFactor: 0.90,
              heightFactor: 0.90,
              child: Container(
                decoration: BoxDecoration(
                  color: nym.bgSecondary,
                  border: Border.all(color: nym.glassBorder),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    // --shadow-lg: 0 8px 32px rgba(0,0,0,0.5)
                    const BoxShadow(
                      color: Color(0x80000000),
                      blurRadius: 32,
                      offset: Offset(0, 8),
                    ),
                    // --shadow-glow: 0 0 20px rgb(from primary / 0.1)
                    BoxShadow(color: nym.primaryA(0.1), blurRadius: 20),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _header(nym),
                    Expanded(child: _body(style)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(NymColors nym) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 8, 16),
      decoration: BoxDecoration(
        color: const Color(0x26000000), // rgba(0,0,0,0.15)
        border: Border(bottom: BorderSide(color: nym.glassBorder)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'GEOHASH EXPLORER',
              style: TextStyle(
                fontSize: 18,
                color: nym.primary,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: Icon(Icons.close, color: nym.textDim, size: 18),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _body(GeoMapStyle style) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // On first layout (or resize) clamp the view to the new size.
        if (size != _lastSize) {
          _lastSize = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _view = _view.clamped(size));
          });
        }

        // Watch the store so heatmap/dots reflect activity changes, and the
        // proximity flag/location so the "Your Location" legend row + marker
        // appear/disappear live.
        ref.watch(appStateProvider);
        ref.watch(settingsProvider.select((s) => s.sortByProximity));
        ref.watch(userLocationProvider);
        final channels = _channels();

        // Keep the precomputed heatmap image in sync with the current inputs.
        _maybeRebuildHeat(size, channels);

        final narrow = size.width < kGlobeNarrowBreakpoint;

        return Stack(
          fit: StackFit.expand,
          children: [
            _mapGestureLayer(size, style, channels),
            _topLeftControls(size, narrow),
            _bottomControls(narrow),
            _legend(narrow),
            if (_selected != null) _infoPanel(_selected!, narrow),
          ],
        );
      },
    );
  }

  Widget _mapGestureLayer(
    Size size,
    GeoMapStyle style,
    List<GeohashChannelPoint> channels,
  ) {
    // Desktop cursor (F6): `grabbing` while dragging, `click` over a dot, else
    // `grab` — mirrors `onPointerMove`/`onPointerDown` in geohash-globe.js.
    final cursor = _dragging
        ? SystemMouseCursors.grabbing
        : (_hoveredGeohash != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.grab);

    return MouseRegion(
      cursor: cursor,
      onHover: (event) {
        // Only update the hovered dot when not dragging (PWA gates on
        // `!dragging`). Touch taps drive selection separately via onTapUp.
        if (_dragging) return;
        final ch = _channelAt(event.localPosition, size);
        final gh = ch?.geohash;
        if (gh != _hoveredGeohash) {
          setState(() => _hoveredGeohash = gh);
        }
      },
      onExit: (_) {
        // Clear hover unless a dot is selected (keep the selected dot enlarged).
        final keep = _selected?.geohash;
        if (_hoveredGeohash != null && _hoveredGeohash != keep) {
          setState(() => _hoveredGeohash = keep);
        }
      },
      child: Listener(
        onPointerSignal: (event) {
          if (event is PointerScrollEvent) {
            final factor = math.exp(-event.scrollDelta.dy * 0.0015);
            _setView(
              _view.zoomedAt(factor, event.localPosition, size),
              size,
            );
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _onTapUp(d, size),
          onScaleStart: (d) {
            _dragStartView = _view;
            setState(() => _dragging = true);
          },
          onScaleUpdate: (d) {
            final start = _dragStartView ?? _view;
            // Pan: translate the focal-point delta into degrees.
            final s = start.scale(size);
            var v = start.copyWith(
              cx: start.cx - d.focalPointDelta.dx / s,
              cy: start.cy + d.focalPointDelta.dy / s,
            );
            // Pinch zoom around the focal point.
            if (d.scale != 1.0) {
              v = v.zoomedAt(d.scale, d.localFocalPoint, size);
            }
            _dragStartView = v; // accumulate for incremental deltas
            _setView(v, size);
          },
          onScaleEnd: (_) {
            _dragStartView = null;
            setState(() => _dragging = false);
          },
          child: RepaintBoundary(
            child: CustomPaint(
              size: size,
              painter: GeoMapPainter(
                view: _view,
                style: style,
                features: _features,
                channels: channels,
                heatmap: _heatmap,
                daynight: _daynight,
                grid: _grid,
                hoveredGeohash: _hoveredGeohash,
                userLocation: _userLocation(),
                heatmapImage: _heatImage,
                repaint: _ticker,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _topLeftControls(Size size, bool narrow) {
    // PWA: `.geohash-controls-tl` top/left 20px, → 10px under 768px.
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      top: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn('+',
              onTap: () =>
                  _setView(_view.zoomedAt(1.6, size.center(Offset.zero), size),
                      size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn('−',
              onTap: () => _setView(
                  _view.zoomedAt(1 / 1.6, size.center(Offset.zero), size), size),
              width: 34),
          const SizedBox(width: 10),
          _controlBtn('Reset View', onTap: () => _resetView(size)),
        ],
      ),
    );
  }

  Widget _bottomControls(bool narrow) {
    // PWA: `.geohash-controls` bottom/left 20px, → 10px under 768px.
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      left: inset,
      child: Row(
        children: [
          _controlBtn('Heat',
              active: _heatmap,
              onTap: () => setState(() => _heatmap = !_heatmap)),
          const SizedBox(width: 10),
          _controlBtn('Day / Night',
              active: _daynight,
              onTap: () => setState(() => _daynight = !_daynight)),
          const SizedBox(width: 10),
          _controlBtn('Geohash',
              active: _grid, onTap: () => setState(() => _grid = !_grid)),
        ],
      ),
    );
  }

  Widget _legend(bool narrow) {
    final nym = context.nym;
    // Show the "Your Location" row only when the PWA would (`showYourLocation`:
    // proximity sort on AND a known location), matching geohash-globe.js:236.
    final showYourLocation = _userLocation() != null;
    // On narrow layouts the font shrinks 10→9 and the inset moves 20→10.
    final fontSize = narrow ? 9.0 : 10.0;
    final inset = narrow ? 10.0 : 20.0;
    return Positioned(
      bottom: inset,
      right: inset,
      child: Container(
        // `.geohash-legend` padding 0 14px; the items carry the vertical margin.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xB3000000), // rgba(0,0,0,0.7)
          border: Border.all(color: nym.glassBorder),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Active row: dot (with primary glow) + "Active" + window control.
            _legendRow(
              dotColor: nym.primary,
              // `.nm-geo-1 { box-shadow: 0 0 5px var(--primary); }`
              glow: nym.primary,
              label: 'Active',
              fontSize: fontSize,
              trailing: narrow ? _windowSelect(nym) : _windowGroup(nym),
            ),
            if (showYourLocation) ...[
              const SizedBox(height: 5),
              _legendRow(
                dotColor: nym.warning, // `.nm-geo-2 { background: var(--warning); }`
                label: 'Your Location',
                fontSize: fontSize,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _legendRow({
    required Color dotColor,
    required String label,
    required double fontSize,
    Color? glow,
    Widget? trailing,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
            boxShadow: glow == null
                ? null
                : [BoxShadow(color: glow, blurRadius: 5)],
          ),
        ),
        const SizedBox(width: 8),
        Text(label,
            style: TextStyle(fontSize: fontSize, color: const Color(0xFFE0E0E0))),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          trailing,
        ],
      ],
    );
  }

  Widget _windowGroup(NymColors nym) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final h in kActiveWindowOptions)
            _windowBtn(h, h == _activeWindowHours, nym),
        ],
      ),
    );
  }

  /// The compact `<select>` fallback shown under 768px in place of the button
  /// group (`.geohash-window-select`: rgba(255,255,255,0.05) bg, glassBorder,
  /// fontSize 11, padding 2/6).
  Widget _windowSelect(NymColors nym) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x0DFFFFFF), // rgba(255,255,255,0.05)
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: _activeWindowHours,
          isDense: true,
          dropdownColor: const Color(0xF2000000),
          iconSize: 14,
          icon: Icon(Icons.arrow_drop_down, color: nym.text),
          style: TextStyle(fontSize: 11, color: nym.text),
          items: [
            for (final h in kActiveWindowOptions)
              DropdownMenuItem<int>(value: h, child: Text('${h}h')),
          ],
          onChanged: (h) {
            if (h != null) setState(() => _activeWindowHours = h);
          },
        ),
      ),
    );
  }

  Widget _windowBtn(int hours, bool active, NymColors nym) {
    return InkWell(
      onTap: () => setState(() => _activeWindowHours = hours),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        color: active ? nym.primaryA(0.18) : Colors.transparent,
        child: Text(
          '${hours}h',
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: active ? nym.primary : nym.textDim,
          ),
        ),
      ),
    );
  }

  Widget _infoPanel(GeohashChannelPoint ch, bool narrow) {
    final nym = context.nym;

    // PWA rows (channels.js:361-372): Coordinates (decimal, 4dp), Location
    // (reverse-geocoded, "Loading location..." until resolved), Distance (only
    // when a user location is known), Messages. No Status row.
    final coords =
        '${ch.lat.toStringAsFixed(4)}, ${ch.lng.toStringAsFixed(4)}';
    final user = _userLocation();
    final distance = user == null
        ? null
        : '${_distanceKm(user.lat, user.lng, ch.lat, ch.lng).toStringAsFixed(1)} km away';

    final rows = <Widget>[
      _infoRow('Coordinates', coords, nym),
      _infoRow('Location', _locationInfo, nym),
      if (distance != null) _infoRow('Distance', distance, nym),
      _infoRow('Messages', '${ch.messages}', nym, isLast: true),
    ];

    final panel = Container(
      width: narrow ? null : 300, // narrow: stretch via Positioned left/right.
      padding: const EdgeInsets.fromLTRB(16, 16, 36, 16),
      decoration: BoxDecoration(
        color: const Color(0xB3000000), // rgba(0,0,0,0.7)
        border: Border.all(color: nym.glassBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  // `.geohash-info-title { text-transform: lowercase; }`
                  '#${ch.geohash.toLowerCase()}',
                  style: TextStyle(
                    color: nym.primary,
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
              ),
              InkWell(
                onTap: () => setState(() => _selected = null),
                child: Icon(Icons.close, size: 14, color: nym.textDim),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...rows,
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => _join(ch.geohash),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.all(9),
                backgroundColor: nym.primaryA(0.1),
                foregroundColor: nym.primary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(4),
                  side: BorderSide(color: nym.primaryA(0.3)),
                ),
              ),
              child: Text(
                // PWA: `Go to Channel` when joined, else `Join Channel`
                // (uppercased by `.geohash-join-btn { text-transform: uppercase }`).
                ch.isJoined ? 'GO TO CHANNEL' : 'JOIN CHANNEL',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.5),
              ),
            ),
          ),
        ],
      ),
    );

    // Under 768px the panel becomes a fixed bottom bar (bottom:60 left/right:10,
    // max-width:none); otherwise it sits top-right (top:20 right:20).
    return narrow
        ? Positioned(bottom: 60, left: 10, right: 10, child: panel)
        : Positioned(top: 20, right: 20, child: panel);
  }

  /// Haversine great-circle distance in km (`calculateDistance`,
  /// geohash-globe.js:1271, R = 6371).
  double _distanceKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    const deg = math.pi / 180;
    final dLat = (lat2 - lat1) * deg;
    final dLon = (lon2 - lon1) * deg;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * deg) *
            math.cos(lat2 * deg) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  /// One info row rendered as `Label: value` on a single wrapped line, with the
  /// PWA's 5px vertical margin/padding and a 1px bottom hairline (`.geohash-
  /// info-item`); the last row drops the border.
  Widget _infoRow(String label, String value, NymColors nym,
      {bool isLast = false}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 5),
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: isLast
          ? null
          : BoxDecoration(
              border: Border(bottom: BorderSide(color: nym.glassBorder)),
            ),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontSize: 12,
                color: nym.text,
                fontWeight: FontWeight.w700, // <strong>
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(fontSize: 12, color: nym.text),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controlBtn(
    String label, {
    required VoidCallback onTap,
    bool active = false,
    double? width,
  }) {
    final nym = context.nym;
    return SizedBox(
      width: width,
      child: Material(
        color: active ? nym.primaryA(0.18) : const Color(0xB3000000),
        borderRadius: BorderRadius.circular(4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: width != null
                ? const EdgeInsets.symmetric(vertical: 8)
                : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              border: Border.all(
                  color: active ? nym.primaryA(0.5) : nym.glassBorder),
              borderRadius: BorderRadius.circular(4),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: width != null ? 16 : 11,
                fontWeight: width != null ? FontWeight.w600 : FontWeight.w500,
                color: active ? nym.primary : nym.text,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
