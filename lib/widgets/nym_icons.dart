import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// The exact PWA inline-SVG icons (feather-style + a couple of custom paths),
/// reproduced verbatim from `index.html` so the Flutter chrome matches the web
/// app pixel-for-pixel instead of approximating with Material glyphs.
///
/// Each entry is the raw `<svg>` markup the PWA ships. They are rendered through
/// [NymSvgIcon], which tints the whole drawing to a single colour with a
/// `srcIn` filter — so the same string works whether the path is stroked
/// (feather icons: `fill:none; stroke:currentColor`) or filled (the share /
/// filled-star glyphs).
class NymIcons {
  NymIcons._();

  /// `#channelBackBtn` — feather chevron-left (stroke).
  static const String chevronLeft =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="15 18 9 12 15 6"/></svg>';

  /// `#channelForwardBtn` — feather chevron-right (stroke).
  static const String chevronRight =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="9 6 15 12 9 18"/></svg>';

  /// `#favoriteChannelBtn` inactive — the custom 5-point star, OUTLINE only
  /// (`.favorite-channel-btn svg { fill:none; stroke:currentColor }`).
  static const String starOutline =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linejoin="round">'
      '<path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 '
      'L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';

  /// `#favoriteChannelBtn.active` — the SAME star, FILLED
  /// (`.favorite-channel-btn.active svg { fill:currentColor; stroke:currentColor }`,
  /// tinted gold by the caller).
  static const String starFilled =
      '<svg viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" '
      'stroke-width="2" stroke-linejoin="round">'
      '<path d="M12 2 L14.9 8.6 L22 9.3 L16.5 14 L18.2 21 L12 17.3 L5.8 21 '
      'L7.5 14 L2 9.3 L9.1 8.6 Z"/></svg>';

  /// `#shareChannelBtn` — the filled "share nodes" glyph (NOT the iOS share box).
  static const String shareNodes =
      '<svg viewBox="0 0 24 24" fill="currentColor">'
      '<path d="M18 16.08c-.76 0-1.44.3-1.96.77L8.91 12.7c.05-.23.09-.46.09-.7s-.04-.47-.09-.7l7.05-4.11c.54.5 1.25.81 2.04.81 1.66 0 3-1.34 3-3s-1.34-3-3-3-3 1.34-3 3c0 .24.04.47.09.7L8.04 9.81C7.5 9.31 6.79 9 6 9c-1.66 0-3 1.34-3 3s1.34 3 3 3c.79 0 1.5-.31 2.04-.81l7.12 4.16c-.05.21-.08.43-.08.65 0 1.61 1.31 2.92 2.92 2.92 1.61 0 2.92-1.31 2.92-2.92s-1.31-2.92-2.92-2.92z"/></svg>';

  /// `#audioCallBtn` — feather phone (stroke).
  static const String phone =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"/></svg>';

  /// `#videoCallBtn` — feather video (stroke).
  static const String video =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polygon points="23 7 16 12 23 17 23 7"/>'
      '<rect x="1" y="5" width="15" height="14" rx="2" ry="2"/></svg>';

  /// `.notifications-btn` — feather bell (stroke).
  static const String bell =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9"/>'
      '<path d="M13.73 21a2 2 0 0 1-3.46 0"/></svg>';

  /// `data-action="openShop"` ("Flair") — the feather star POLYGON (distinct from
  /// the favorite button's custom star path).
  static const String starFlair =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"/></svg>';

  /// `data-action="showSettings"` — feather gear (stroke).
  static const String settings =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="3"/>'
      '<path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>';

  /// `data-action="showAbout"` — feather info (stroke).
  static const String info =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="12" r="10"/>'
      '<line x1="12" y1="16" x2="12" y2="12"/>'
      '<line x1="12" y1="8" x2="12.01" y2="8"/></svg>';

  /// `data-action="signOut"` — feather log-out (stroke).
  static const String logout =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>'
      '<polyline points="16 17 21 12 16 7"/>'
      '<line x1="21" y1="12" x2="9" y2="12"/></svg>';

  /// `.mobile-menu-toggle` — feather menu (hamburger, stroke).
  static const String menu =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<line x1="3" y1="6" x2="21" y2="6"/>'
      '<line x1="3" y1="12" x2="21" y2="12"/>'
      '<line x1="3" y1="18" x2="21" y2="18"/></svg>';

  /// Notifications-disabled variant — feather bell-off (stroke). The PWA header
  /// always shows the plain bell; this keeps the native "muted" affordance using
  /// the matching feather glyph rather than a Material substitute.
  static const String bellOff =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<path d="M13.73 21a2 2 0 0 1-3.46 0"/>'
      '<path d="M18.63 13A17.89 17.89 0 0 1 18 8"/>'
      '<path d="M6.26 6.26A5.86 5.86 0 0 0 6 8c0 7-3 9-3 9h14"/>'
      '<path d="M18 8a6 6 0 0 0-9.33-5"/>'
      '<line x1="1" y1="1" x2="23" y2="23"/></svg>';

  /// `.group-header-svg` (groups.js:2910): the three-figure group glyph, drawn in
  /// a 24×24 viewBox at stroke-width 1.75. Verbatim PWA path data.
  static const String groupGlyph =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.75" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<circle cx="12" cy="7" r="2.75"/>'
      '<path d="M5 21v-1.5a7 7 0 0 1 14 0V21"/>'
      '<circle cx="4.5" cy="9.5" r="2"/>'
      '<path d="M1 20v-1a4.5 4.5 0 0 1 5.5-4.35"/>'
      '<circle cx="19.5" cy="9.5" r="2"/>'
      '<path d="M23 20v-1a4.5 4.5 0 0 0-5.5-4.35"/></svg>';

  /// `.friend-badge` (users.js:1923): a person-with-plus glyph in a 16×16 viewBox
  /// (filled head/body + stroked plus). Verbatim PWA markup; tinted to the friend
  /// colour by the caller.
  static const String friendBadge =
      '<svg viewBox="0 0 16 16" fill="currentColor">'
      '<circle cx="6" cy="5" r="2.5"/>'
      '<path d="M 1.5 14 C 1.5 10.5 3.5 9 6 9 C 8.5 9 10.5 10.5 10.5 14"/>'
      '<line x1="13" y1="6" x2="13" y2="10" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>'
      '<line x1="11" y1="8" x2="15" y2="8" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>';

  /// `#channelMeta` E2E notice prefix for PMs/groups — feather lock (`lockSvg` /
  /// `lockSvgPM`, identical paths; stroke).
  static const String lock =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/>'
      '<path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>';

  /// The native-only "Transfers" pill (no PWA header equivalent) — feather repeat
  /// (stroke), keeping the chrome consistent with the feather icon family.
  static const String transfers =
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" '
      'stroke-linecap="round" stroke-linejoin="round">'
      '<polyline points="17 1 21 5 17 9"/>'
      '<path d="M3 11V9a4 4 0 0 1 4-4h14"/>'
      '<polyline points="7 23 3 19 7 15"/>'
      '<path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>';
}

/// Renders one of the [NymIcons] SVG strings at [size], tinted to [color] with a
/// `srcIn` filter (so a single colour drives both stroked and filled glyphs,
/// matching the PWA's `currentColor` behaviour).
class NymSvgIcon extends StatelessWidget {
  const NymSvgIcon(
    this.svg, {
    super.key,
    required this.size,
    required this.color,
  });

  final String svg;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      svg,
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
