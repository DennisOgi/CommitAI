import 'dart:async';

import '../models/models.dart';

/// An incoming call surfaced to the UI (from FCM push, or the demo simulator).
class IncomingCall {
  IncomingCall({required this.callId, required this.callerName, required this.recorded, required this.mode, this.roomUrl});
  final String callId;
  final String callerName;
  final bool recorded;
  final AppMode mode;
  final String? roomUrl;
}

typedef CorporateLoginResult = ({String corpSession, Session session, List<HeldCall> held});
typedef AcceptResult = ({String roomUrl, String token, bool recorded, String? disclosure});

abstract class Backend {
  /// Incoming calls and "held while you were at work" notices.
  final incoming = StreamController<IncomingCall>.broadcast();

  Future<Session> me();
  Future<CorporateLoginResult> corporateLogin(String corpCode, String employeeId, String pin);
  Future<List<HeldCall>> setMode(AppMode mode, {String? corpSession});

  Future<List<Contact>> contacts();
  Future<Contact> addContact({required String name, String? company, String? phone, String? email});

  Future<List<CallRecord>> calls();
  Future<CallStart> startCall({bool pstn = false, String? calleeUserId, String? phone, String? contactId, String? displayName});
  Future<AcceptResult> acceptCall(String callId);
  Future<void> declineCall(String callId);
  Future<void> endCall(String callId);
  Future<CallDetail> callDetail(String callId);
  Future<CallDetail> submitReview(
    String callId, {
    required List<String> accept,
    required List<String> reject,
    Map<String, Map<String, dynamic>> edits = const {},
    List<Map<String, dynamic>> add = const [],
  });

  Future<List<Commitment>> commitments({bool team = false, String? memberId, String? status});
  Future<Commitment> updateCommitment(String id, {CommitmentStatus? status, String? title, DateTime? dueAt, String? note});
  Future<void> comment(String id, String text);
  Future<void> nudge(String id);
  Future<List<CommitmentEvent>> events(String id);
  Future<Dashboard> dashboard({int days = 30});

  Future<void> registerDevice(String platform, String? pushToken);

  /// The employee flagged a moment of a live work call as a commitment.
  Future<void> flagMoment(String callId, int offsetMs) async {}

  // ---- Company onboarding (not available in the demo) ----
  Never _noDemo() => throw UnsupportedError('Not available in the demo.');

  /// Register a company; the user becomes its admin and is switched to Work mode.
  Future<CorporateLoginResult> createCompany({required String name, required String pin, String? title}) async => _noDemo();
  Future<List<OrgInvite>> invites() async => [];
  Future<CorporateLoginResult> joinCompany(String membershipId, String pin) async => _noDemo();
  Future<void> changeWorkPin(String currentPin, String newPin) async => _noDemo();
  Future<OrgOverview> orgOverview() async => _noDemo();
  Future<void> updateOrg(Map<String, dynamic> patch) async => _noDemo();
  Future<List<OrgMember>> orgMembers() async => [];
  Future<MemberCredentials> addMember(Map<String, dynamic> member) async => _noDemo();

  /// Each result is either credentials or an error message for that row.
  Future<List<(MemberCredentials?, String?, String)>> addMembers(List<Map<String, dynamic>> members) async => _noDemo();
  Future<OrgMember> updateMember(String id, Map<String, dynamic> patch) async => _noDemo();
  Future<MemberCredentials> resetMemberPin(String id, {bool unlinkAccount = false}) async => _noDemo();

  /// People on Commit AI matching a name (2+ letters) or an exact email.
  Future<List<PlatformUser>> searchUsers(String q) async => [];

  /// Save someone found by search as a contact.
  Future<Contact> addAppUser({required String name, required String userId}) =>
      throw UnsupportedError('Not available in the demo.');

  /// "Let people find me" on/off. Returns the saved value.
  Future<bool> setDiscoverable(bool on) async => on;

  /// Personal-call recording on/off. Returns the saved value.
  Future<bool> setRecordPersonalCalls(bool on) async => on;

  /// Import the phone's address book into personal contacts.
  /// Each entry: {name, phones: [...], emails: [...]}. Returns (imported, skipped, onApp).
  Future<({int imported, int skipped, int onApp})> importContacts(List<Map<String, dynamic>> contacts) async =>
      (imported: 0, skipped: contacts.length, onApp: 0);

  /// Send a client-side failure (e.g. couldn't join the call audio) to the server log.
  Future<void> reportProblem(String where, String message, {String? callId}) async {}

  /// Calls ringing for this user now (polled when push isn't configured).
  Future<List<IncomingCall>> ringing() async => const [];

  /// Run extraction on a call without a live bot (demo + dev servers).
  Future<void> simulateExtraction(String callId);
}

class ApiException implements Exception {
  ApiException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}
