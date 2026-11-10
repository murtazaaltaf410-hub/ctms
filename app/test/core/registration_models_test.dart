import 'package:ctms/core/models/registration.dart';
import 'package:ctms/features/admin/admin_models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> studentJson({String status = 'approved'}) => {
  'id': 's1',
  'full_name': 'Aisha Khan',
  'email': 'aisha@uok.edu.in',
  'phone': '+919876543210',
  'department': 'Physics',
  'route_id': 'r1',
  'route_name': 'North Loop',
  'requested_bus_label': 'Bus 2',
  'claims_registered': true,
  'status': status,
  'bus_id': 'b1',
  'bus_label': 'Bus 2',
  'admin_note': 'ok',
  'reviewed_at': '2026-11-02T09:00:00Z',
  'created_at': '2026-11-01T08:00:00Z',
};

void main() {
  group('StudentRegistration', () {
    test('parses every field and maps status to the gate', () {
      final r = StudentRegistration.fromJson({
        'status': 'rejected',
        'full_name': 'Aisha Khan',
        'phone': '+919876543210',
        'department': 'Physics',
        'route_id': 'r1',
        'route_name': 'North Loop',
        'requested_bus_label': 'Bus 2',
        'claims_registered': true,
        'bus_id': null,
        'bus_label': null,
        'admin_note': 'Wrong route',
        'reviewed_at': '2026-11-02T09:00:00Z',
      });
      expect(r.status, RegistrationStatus.rejected);
      expect(r.gate, RegistrationGate.rejected);
      expect(r.fullName, 'Aisha Khan');
      expect(r.routeName, 'North Loop');
      expect(r.claimsRegistered, isTrue);
      expect(r.adminNote, 'Wrong route');
      expect(r.reviewedAt!.isUtc, isTrue);
      expect(r.busId, isNull);
    });

    test('defaults: nulls and unknown status fall back to pending', () {
      final r = StudentRegistration.fromJson({
        'status': 'weird',
        'full_name': 'A',
      });
      expect(r.status, RegistrationStatus.pending);
      expect(r.gate, RegistrationGate.pending);
      expect(r.claimsRegistered, isFalse);
      expect(r.reviewedAt, isNull);
    });

    test('approved status maps to the approved gate', () {
      final r = StudentRegistration.fromJson({
        'status': 'approved',
        'full_name': 'A',
        'bus_id': 'b1',
        'bus_label': 'Bus 2',
      });
      expect(r.gate, RegistrationGate.approved);
      expect(r.busLabel, 'Bus 2');
    });
  });

  test('RegistrationInput omits an empty bus label', () {
    const base = RegistrationInput(
      fullName: 'A',
      phone: '+919876543210',
      department: 'D',
      enrollmentNo: 'E1',
      homeAddress: 'Hazratbal',
      routeId: 'r1',
      claimsRegistered: false,
    );
    expect(base.toJson(), {
      'full_name': 'A',
      'phone': '+919876543210',
      'department': 'D',
      'enrollment_no': 'E1',
      'home_address': 'Hazratbal',
      'route_id': 'r1',
      'claims_registered': false,
    });
    const withBus = RegistrationInput(
      fullName: 'A',
      phone: '+919876543210',
      department: 'D',
      enrollmentNo: 'E1',
      homeAddress: 'Hazratbal',
      routeId: 'r1',
      claimsRegistered: true,
      requestedBusLabel: 'Bus 2',
    );
    expect(withBus.toJson()['requested_bus_label'], 'Bus 2');
  });

  test('NearestRoute and RosterStudent parse', () {
    final n = NearestRoute.fromJson({
      'route_id': 'r1',
      'route_name': 'North Loop',
      'offset_m': 120,
    });
    expect(n.routeId, 'r1');
    expect(n.offsetM, 120.0);
    final s = RosterStudent.fromJson({
      'name': 'Aisha',
      'department': 'Physics',
    });
    expect(s.name, 'Aisha');
    expect(s.department, 'Physics');
    expect(RosterStudent.fromJson({'name': 'B'}).department, isNull);
  });

  group('AdminStudent', () {
    test('parses a full item', () {
      final s = AdminStudent.fromJson(studentJson());
      expect(s.id, 's1');
      expect(s.status, RegistrationStatus.approved);
      expect(s.email, 'aisha@uok.edu.in');
      expect(s.busLabel, 'Bus 2');
      expect(s.claimsRegistered, isTrue);
      expect(s.createdAt.isUtc, isTrue);
      expect(s.reviewedAt, isNotNull);
    });

    test('optional fields may be absent', () {
      final s = AdminStudent.fromJson({
        'id': 's2',
        'full_name': 'B',
        'status': 'pending',
        'created_at': '2026-11-01T08:00:00Z',
      });
      expect(s.phone, isNull);
      expect(s.claimsRegistered, isFalse);
      expect(s.status, RegistrationStatus.pending);
    });
  });

  group('StudentSummary', () {
    final summary = StudentSummary.fromJson({
      'totals': {'pending': 2, 'approved': 3, 'rejected': 1, 'total': 6},
      'buses': [
        {
          'bus_id': 'b1',
          'label': 'Bus 1',
          'route_id': 'r1',
          'capacity': 40,
          'assigned': 18,
          'seats_left': 22,
        },
        {
          'bus_id': 'b2',
          'label': 'Bus 2',
          'route_id': 'r1',
          'capacity': 10,
          'assigned': 10,
          'seats_left': 0,
        },
        {
          'bus_id': 'b3',
          'label': 'Bus 3',
          'route_id': 'r1',
          'capacity': null,
          'assigned': 4,
          'seats_left': null,
        },
        {
          'bus_id': 'b4',
          'label': 'Bus 4',
          'route_id': 'r2',
          'capacity': 5,
          'assigned': 0,
          'seats_left': 5,
        },
      ],
      'routes': [
        {
          'route_id': 'r1',
          'route_name': 'North Loop',
          'pending': 2,
          'approved': 3,
          'rejected': 1,
        },
      ],
    });

    test('totals per status', () {
      expect(summary.totals.forStatus(null), 6);
      expect(summary.totals.forStatus(RegistrationStatus.pending), 2);
      expect(summary.totals.forStatus(RegistrationStatus.approved), 3);
      expect(summary.totals.forStatus(RegistrationStatus.rejected), 1);
      expect(summary.routes.single.routeName, 'North Loop');
    });

    test('BusSeats seat maths and description', () {
      final b1 = summary.buses[0];
      expect(b1.hasFreeSeat, isTrue);
      expect(b1.describe('North Loop'), contains('18/40'));
      expect(summary.buses[1].hasFreeSeat, isFalse);
      expect(summary.buses[2].capacity, isNull);
      expect(summary.buses[2].hasFreeSeat, isFalse);
      expect(summary.buses[2].describe(null), contains('capacity not set'));
    });

    test('busesWithSeats is limited to the route and free seats', () {
      expect(summary.busesWithSeats('r1').map((b) => b.busId), ['b1']);
      expect(summary.busesWithSeats('r2').map((b) => b.busId), ['b4']);
      expect(summary.busesWithSeats('nope'), isEmpty);
    });
  });

  group('normalisePhone', () {
    test('Indian numbers get +91', () {
      expect(normalisePhone('98765 43210'), '+919876543210');
      expect(normalisePhone('098765-43210'), '+919876543210');
      expect(normalisePhone('(98765) 43210'), '+919876543210');
    });
    test('international forms are kept', () {
      expect(normalisePhone('+91 98765 43210'), '+919876543210');
      expect(normalisePhone('0091 98765 43210'), '+919876543210');
      expect(normalisePhone('+44 7911 123456'), '+447911123456');
    });
    test('invalid input is null', () {
      expect(normalisePhone(''), isNull);
      expect(normalisePhone('abc'), isNull);
      expect(normalisePhone('123'), isNull);
      expect(normalisePhone('+0123456789'), isNull);
      expect(normalisePhone('9876543210123456789'), isNull);
    });
  });

  test('V1.3 registration fields parse; old payloads count as complete', () {
    final r = StudentRegistration.fromJson({
      'status': 'pending',
      'full_name': 'A',
      'enrollment_no': 'E1',
      'home_address': 'Hazratbal',
      'has_photo': false,
      'complete': false,
    });
    expect(r.enrollmentNo, 'E1');
    expect(r.homeAddress, 'Hazratbal');
    expect(r.hasPhoto, isFalse);
    expect(r.complete, isFalse);
    final old = StudentRegistration.fromJson({
      'status': 'pending',
      'full_name': 'A',
    });
    expect(old.complete, isTrue);
  });
}
