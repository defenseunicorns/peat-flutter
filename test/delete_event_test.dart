// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

// Tests for delete-event handling: DocumentChange with ChangeType.delete
// round-trips correctly through JSON, and the ChangeType codec maps the
// 'delete' string to the enum variant.

import 'package:flutter_test/flutter_test.dart';
import 'package:peat_flutter/peat_flutter.dart';

void main() {
  group('DocumentChange — delete events', () {
    test('ChangeType.delete round-trips through JSON', () {
      final change = DocumentChange(
        collection: 'markers',
        docId: 'pin-001',
        changeType: ChangeType.delete,
        origin: const ChangeOrigin.local(),
      );
      final json = change.toJson();
      expect(json['changeType'], 'delete');

      final restored = DocumentChange.fromJson(json);
      expect(restored.changeType, ChangeType.delete);
      expect(restored.collection, 'markers');
      expect(restored.docId, 'pin-001');
    });

    test('delete and upsert are distinct change types', () {
      final del = DocumentChange.fromJson({
        'collection': 'markers',
        'docId': 'pin-001',
        'changeType': 'delete',
        'origin': null,
      });
      final ups = DocumentChange.fromJson({
        'collection': 'markers',
        'docId': 'pin-001',
        'changeType': 'upsert',
        'origin': null,
      });
      expect(del.changeType, isNot(equals(ups.changeType)));
      expect(del, isNot(equals(ups)));
    });

    test('ChangeType.delete name is "delete"', () {
      expect(ChangeType.delete.name, 'delete');
    });

    test('ChangeType.upsert name is "upsert"', () {
      expect(ChangeType.upsert.name, 'upsert');
    });

    test('remote delete preserves peer origin', () {
      final change = DocumentChange.fromJson({
        'collection': 'nodes',
        'docId': 'node-abc',
        'changeType': 'delete',
        'origin': 'peer-xyz',
      });
      expect(change.changeType, ChangeType.delete);
      expect(change.origin.isLocal, isFalse);
      expect(change.origin.peerId, 'peer-xyz');
    });
  });
}
