// Copyright 2026 Defense Unicorns
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_test/flutter_test.dart';
import 'package:peat_flutter/peat_flutter.dart';

void main() {
  const marker = MarkerInfo(
    uid: 'pin-001',
    markerType: 'b-m-p-w',
    lat: 38.8895,
    lon: -77.0352,
    hae: 15.0,
    ts: 1720000000000,
    callsign: 'ALPHA-1',
    color: 0xFFFF0000,
    cellId: 'cell-a',
    deleted: false,
  );

  group('MarkerInfo — JSON round-trip', () {
    test('toJson includes all fields', () {
      final json = marker.toJson();
      expect(json['uid'], 'pin-001');
      expect(json['markerType'], 'b-m-p-w');
      expect(json['lat'], 38.8895);
      expect(json['lon'], -77.0352);
      expect(json['hae'], 15.0);
      expect(json['ts'], 1720000000000);
      expect(json['callsign'], 'ALPHA-1');
      expect(json['color'], 0xFFFF0000);
      expect(json['cellId'], 'cell-a');
      expect(json['deleted'], false);
    });

    test('fromJson reconstructs identical marker', () {
      final roundTripped = MarkerInfo.fromJson(marker.toJson());
      expect(roundTripped, equals(marker));
    });

    test('nullable fields round-trip as null', () {
      const sparse = MarkerInfo(
        uid: 'pin-002',
        markerType: 'a-f-G-U-C',
        lat: 0,
        lon: 0,
        hae: null,
        ts: 0,
        callsign: null,
        color: null,
        cellId: null,
        deleted: false,
      );
      final json = sparse.toJson();
      expect(json['hae'], isNull);
      expect(json['callsign'], isNull);
      expect(json['color'], isNull);
      expect(json['cellId'], isNull);

      final restored = MarkerInfo.fromJson(json);
      expect(restored, equals(sparse));
    });

    test('fromJson coerces int lat/lon to double', () {
      final json = marker.toJson();
      json['lat'] = 39;
      json['lon'] = -77;
      final m = MarkerInfo.fromJson(json);
      expect(m.lat, 39.0);
      expect(m.lon, -77.0);
    });
  });

  group('MarkerInfo — copyWith', () {
    test('preserves fields when no overrides', () {
      final copy = marker.copyWith();
      expect(copy, equals(marker));
    });

    test('overrides deleted for soft-delete tombstone', () {
      final tombstone = marker.copyWith(deleted: true);
      expect(tombstone.deleted, isTrue);
      expect(tombstone.uid, marker.uid);
      expect(tombstone.lat, marker.lat);
      expect(tombstone.lon, marker.lon);
    });

    test('can clear nullable fields to null', () {
      final cleared = marker.copyWith(
        hae: null,
        callsign: null,
        color: null,
        cellId: null,
      );
      expect(cleared.hae, isNull);
      expect(cleared.callsign, isNull);
      expect(cleared.color, isNull);
      expect(cleared.cellId, isNull);
    });
  });

  group('MarkerInfo — equality', () {
    test('identical values are equal', () {
      final a = MarkerInfo.fromJson(marker.toJson());
      final b = MarkerInfo.fromJson(marker.toJson());
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different uid is not equal', () {
      final other = marker.copyWith(uid: 'pin-999');
      expect(other, isNot(equals(marker)));
    });

    test('deleted flag changes equality', () {
      final tombstone = marker.copyWith(deleted: true);
      expect(tombstone, isNot(equals(marker)));
    });
  });

  group('MarkerInfo — soft-delete filtering', () {
    test('live markers exclude tombstones', () {
      final markers = [
        marker,
        marker.copyWith(uid: 'pin-002', deleted: true),
        marker.copyWith(uid: 'pin-003'),
      ];
      final live = markers.where((m) => !m.deleted).toList();
      expect(live, hasLength(2));
      expect(live.map((m) => m.uid), containsAll(['pin-001', 'pin-003']));
    });

    test('tombstone preserves original data for CRDT convergence', () {
      final tombstone = marker.copyWith(deleted: true);
      expect(tombstone.uid, marker.uid);
      expect(tombstone.lat, marker.lat);
      expect(tombstone.lon, marker.lon);
      expect(tombstone.callsign, marker.callsign);
      expect(tombstone.ts, marker.ts);
    });
  });
}
