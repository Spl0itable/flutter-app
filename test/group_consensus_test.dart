// Regression tests for group membership state converging across members.
//
//   1. a ban is not undone by a member who missed it advertising a stale
//      roster on its next ordinary message;
//   2. only the group owner's `subject` tag renames the group;
//   3. an unban is authorised for owners AND moderators, and a moderator may
//      add members even when "allow members to add others" is off.
//
// Mirrors scripts/test-group-consensus.mjs in the PWA.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nym_bar/features/groups/group_logic.dart';
import 'package:nym_bar/models/group.dart';
import 'package:nym_bar/state/app_state.dart';

String _pk(int i) => i.toString().padLeft(2, '0') * 32;

Group _seed(
  AppStateNotifier n, {
  required String gid,
  required String owner,
  required List<String> members,
  String name = 'Room',
  List<String> mods = const [],
  List<String> banned = const [],
  bool allowMemberInvites = true,
}) {
  final g = Group(
    id: gid,
    name: name,
    members: [...members],
    createdBy: owner,
    mods: [...mods],
    banned: [...banned],
    allowMemberInvites: allowMemberInvites,
  );
  n.upsertGroup(g);
  return g;
}

void main() {
  group('a ban survives a stale roster on an ordinary message', () {
    test('a banned member is not merged back in from a p-tag roster', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g1';
      final owner = _pk(0), bob = _pk(2), carol = _pk(3);
      final members = [for (var i = 0; i < 6; i++) _pk(i)];
      final g = _seed(n, gid: gid, owner: owner, members: members);

      // Owner bans carol on this client.
      g.members.remove(carol);
      g.banned.add(carol);

      // Bob, who missed the ban, sends a message carrying the pre-ban roster.
      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Room',
        memberPubkeys: members,
        timestampMs: 110000,
        senderPubkey: bob,
      );

      expect(n.groupById(gid)!.members, isNot(contains(carol)));
      expect(n.groupById(gid)!.banned, contains(carol));
    });

    test('a non-banned newcomer in the same roster is still learned', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g1b';
      final owner = _pk(0), bob = _pk(2), carol = _pk(3), dave = _pk(9);
      final members = [for (var i = 0; i < 6; i++) _pk(i)];
      final g = _seed(n, gid: gid, owner: owner, members: members);
      g.members.remove(carol);
      g.banned.add(carol);

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Room',
        memberPubkeys: [...members, dave],
        timestampMs: 120000,
        senderPubkey: bob,
      );

      expect(n.groupById(gid)!.members, contains(dave));
      expect(n.groupById(gid)!.members, isNot(contains(carol)));
    });
  });

  group('the group name is owner-controlled', () {
    test('a non-owner subject tag does not rename the group', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g2';
      final owner = _pk(0);
      final members = [for (var i = 0; i < 4; i++) _pk(i)];
      _seed(n, gid: gid, owner: owner, members: members, name: 'Book Club');

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Not Book Club',
        memberPubkeys: members,
        timestampMs: 500000,
        senderPubkey: _pk(3),
      );

      expect(n.groupById(gid)!.name, 'Book Club');
    });

    test("the owner's subject tag still renames it", () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g2b';
      final owner = _pk(0);
      final members = [for (var i = 0; i < 4; i++) _pk(i)];
      _seed(n, gid: gid, owner: owner, members: members, name: 'Book Club');

      n.mergeGroupFromMessage(
        groupId: gid,
        name: 'Reading Group',
        memberPubkeys: members,
        timestampMs: 510000,
        senderPubkey: owner,
      );

      expect(n.groupById(gid)!.name, 'Reading Group');
    });
  });

  group('moderator privileges', () {
    test('a moderator may lift a ban', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3';
      final owner = _pk(0), mod = _pk(1), carol = _pk(3);
      final members = [owner, mod, _pk(2)];
      _seed(n,
          gid: gid,
          owner: owner,
          members: members,
          mods: [mod],
          banned: [carol]);

      final res = n.applyGroupControl(
        groupId: gid,
        type: GroupControlType.unban,
        tags: [
          ['unban', carol]
        ],
        senderPubkey: mod,
        ts: 400,
        eventId: 'u1',
      );

      expect(res, GroupControlResult.applied);
      expect(n.groupById(gid)!.banned, isNot(contains(carol)));
    });

    test('a plain member may not lift a ban', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final n = container.read(appStateProvider.notifier);
      const gid = 'g3b';
      final owner = _pk(0), mod = _pk(1), plain = _pk(2), carol = _pk(3);
      final members = [owner, mod, plain];
      _seed(n,
          gid: gid,
          owner: owner,
          members: members,
          mods: [mod],
          banned: [carol]);

      final res = n.applyGroupControl(
        groupId: gid,
        type: GroupControlType.unban,
        tags: [
          ['unban', carol]
        ],
        senderPubkey: plain,
        ts: 401,
        eventId: 'u2',
      );

      expect(res, GroupControlResult.unauthorized);
      expect(n.groupById(gid)!.banned, contains(carol));
    });

    test('a moderator can add members when member invites are off', () {
      final owner = _pk(0), mod = _pk(1), plain = _pk(2);
      final off = Group(
        id: 'g4',
        members: [owner, mod, plain],
        createdBy: owner,
        mods: [mod],
        allowMemberInvites: false,
      );
      expect(GroupLogic.canAddMembers(off, owner), isTrue);
      expect(GroupLogic.canAddMembers(off, mod), isTrue);
      expect(GroupLogic.canAddMembers(off, plain), isFalse);

      final on = Group(
        id: 'g5',
        members: [owner, mod, plain],
        createdBy: owner,
        mods: [mod],
      );
      expect(GroupLogic.canAddMembers(on, plain), isTrue);
    });
  });
}
