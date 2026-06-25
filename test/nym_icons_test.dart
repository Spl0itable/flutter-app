import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nym_bar/widgets/nym_icons.dart';

void main() {
  // Guards the exact-PWA icon set: a typo in any path/markup would render blank
  // (or throw) on-device, so assert every glyph parses into an SvgPicture and
  // renders without surfacing an exception.
  testWidgets('every NymIcons glyph parses + renders without error',
      (tester) async {
    const icons = <(String, String)>[
      ('chevronLeft', NymIcons.chevronLeft),
      ('chevronRight', NymIcons.chevronRight),
      ('starOutline', NymIcons.starOutline),
      ('starFilled', NymIcons.starFilled),
      ('shareNodes', NymIcons.shareNodes),
      ('phone', NymIcons.phone),
      ('video', NymIcons.video),
      ('bell', NymIcons.bell),
      ('starFlair', NymIcons.starFlair),
      ('settings', NymIcons.settings),
      ('info', NymIcons.info),
      ('logout', NymIcons.logout),
      ('menu', NymIcons.menu),
      ('bellOff', NymIcons.bellOff),
      ('transfers', NymIcons.transfers),
      ('groupGlyph', NymIcons.groupGlyph),
      ('friendBadge', NymIcons.friendBadge),
      ('lock', NymIcons.lock),
    ];

    for (final (name, svg) in icons) {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: NymSvgIcon(svg, size: 18, color: const Color(0xFF112233)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '$name threw while rendering');
      expect(find.byType(SvgPicture), findsOneWidget, reason: '$name missing');
    }
  });
}
