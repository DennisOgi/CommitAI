import 'package:commit_ai/core/format.dart';
import 'package:commit_ai/data/backend.dart';
import 'package:commit_ai/data/demo_backend.dart';
import 'package:commit_ai/models/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('format', () {
    test('Nigerian number classification', () {
      expect(numberKind('08031234567'), NumberKind.mobile);
      expect(numberKind('+2349012345678'), NumberKind.mobile);
      expect(numberKind('+23412701234'), NumberKind.landline);
      expect(numberKind('12'), NumberKind.unknown);
      expect(toE164('0803 123 4567'), '+2348031234567');
    });

    test('due labels', () {
      expect(dueLabel(null), 'No deadline');
      expect(dueLabel(DateTime.now().subtract(const Duration(days: 3))), startsWith('Overdue'));
      expect(dueLabel(DateTime.now().add(const Duration(minutes: 30))), startsWith('Due in'));
    });

    test('initials', () {
      expect(initials('Ada Okafor'), 'AO');
      expect(initials('Coastal Pharma (front desk)'), 'CD');
      expect(initials('+234 803'), '#');
    });
  });

  group('demo backend enforces the mode rules', () {
    test('Work mode requires corporate login and holds personal calls', () async {
      final b = DemoBackend(persona: 'ada');
      await expectLater(b.setMode(AppMode.corporate, corpSession: 'x'), throwsA(isA<ApiException>()));
      await expectLater(b.corporateLogin('LUMEN', 'EMP-1042', '0000'), throwsA(isA<ApiException>()));

      final login = await b.corporateLogin('lumen', 'emp-1042', '1234');
      expect(login.session.mode, AppMode.corporate);

      // A friend calls while at work: held, not rung.
      final msg = b.simulateIncoming(fromClient: false);
      expect(msg, contains('Held'));

      // Back to personal: the held call is handed over.
      final held = await b.setMode(AppMode.personal);
      expect(held.single.from, 'Chidi Nwosu');
    });

    test('corporate history is invisible in personal mode', () async {
      final b = DemoBackend(persona: 'ada');
      final personal = await b.calls();
      expect(personal.every((c) => c.mode == AppMode.personal), isTrue);
      await expectLater(b.commitments(), throwsA(isA<ApiException>()));
    });

    test('a recorded client call produces commitments to review', () async {
      final b = DemoBackend(persona: 'ada');
      await b.corporateLogin('LUMEN', 'EMP-1042', '1234');
      final start = await b.startCall(pstn: true, phone: '+2348031234567', contactId: 'c-bello');
      expect(start.recorded, isTrue);
      b.markAnswered(start.call.id);
      await b.endCall(start.call.id);
      await b.simulateExtraction(start.call.id);
      final detail = await b.callDetail(start.call.id);
      expect(detail.commitments.where((c) => c.status == CommitmentStatus.pendingReview), isNotEmpty);

      final ids = detail.commitments.map((c) => c.id).toList();
      final reviewed = await b.submitReview(start.call.id, accept: ids.sublist(1), reject: ids.sublist(0, 1));
      expect(reviewed.commitments.where((c) => c.status == CommitmentStatus.cancelled).length, 1);
    });

    test('dashboard is for managers only', () async {
      final ada = DemoBackend(persona: 'ada');
      await ada.corporateLogin('LUMEN', 'EMP-1042', '1234');
      await expectLater(ada.dashboard(), throwsA(isA<ApiException>()));

      final ngozi = DemoBackend(persona: 'ngozi');
      await ngozi.corporateLogin('LUMEN', 'EMP-1001', '1234');
      final d = await ngozi.dashboard();
      expect(d.trend.length, 8);
      expect(d.people.map((p) => p.name), contains('Ada Okafor'));
      expect(d.kpis['on_time_rate'], isNotNull);
    });
  });
}
