import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';
import 'backend.dart';

/// Talks to the Commit AI FastAPI server.
class ApiBackend extends Backend {
  ApiBackend(this.baseUrl, this.token);

  final String baseUrl;

  /// Returns the current bearer token (Supabase access token, or "dev:<id>").
  final Future<String> Function() token;
  final _http = http.Client();

  Future<dynamic> _req(String method, String path, {Object? body, Map<String, String>? query}) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final headers = {'Authorization': 'Bearer ${await token()}', 'Content-Type': 'application/json'};
    final req = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) req.body = jsonEncode(body);
    final http.Response res;
    try {
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 20)));
    } on TimeoutException {
      throw ApiException(0, 'The server took too long to respond. Check your connection.');
    } on http.ClientException {
      throw ApiException(0, "Can't reach the Commit AI server. If your internet is working, the server may be down; try again in a moment.");
    }
    dynamic decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } on FormatException {
      decoded = null;
    }
    if (res.statusCode >= 400) {
      final detail = decoded is Map ? decoded['detail'] : null;
      final message = detail is String
          ? detail
          : detail is List && detail.isNotEmpty && detail.first is Map
              ? 'Please check your input: ${(detail.first as Map)['msg']}'
              : 'Request failed (${res.statusCode})';
      throw ApiException(res.statusCode, message);
    }
    return decoded;
  }

  Session _session(Map<String, dynamic> j) => Session(
        profile: Profile.fromJson(j['profile']),
        mode: j['mode'] == 'corporate' ? AppMode.corporate : AppMode.personal,
        membership: j['membership'] == null ? null : Membership.fromJson(j['membership']),
        organization: j['organization'] == null ? null : Organization.fromJson(j['organization']),
      );

  @override
  Future<Session> me() async => _session(await _req('GET', '/v1/me'));

  @override
  Future<CorporateLoginResult> corporateLogin(String corpCode, String employeeId, String pin) async {
    final j = await _req('POST', '/v1/corporate/login',
        body: {'corp_code': corpCode, 'employee_id': employeeId, 'pin': pin});
    return (
      corpSession: j['corp_session'] as String,
      session: await me(),
      held: [for (final h in j['held_calls'] as List) HeldCall.fromJson(h)],
    );
  }

  @override
  Future<List<HeldCall>> setMode(AppMode mode, {String? corpSession}) async {
    final j = await _req('POST', '/v1/presence', body: {'mode': enumWire(mode), 'corp_session': corpSession});
    return [for (final h in j['held_calls'] as List) HeldCall.fromJson(h)];
  }

  @override
  Future<List<Contact>> contacts() async => [for (final c in await _req('GET', '/v1/contacts')) Contact.fromJson(c)];

  @override
  Future<Contact> addContact({required String name, String? company, String? phone, String? email}) async =>
      Contact.fromJson(await _req('POST', '/v1/contacts', body: {'name': name, 'company': company, 'phone_e164': phone, if (email != null) 'email': email}));

  @override
  Future<List<CallRecord>> calls() async => [for (final c in await _req('GET', '/v1/calls')) CallRecord.fromJson(c)];

  @override
  Future<CallStart> startCall({bool pstn = false, String? calleeUserId, String? phone, String? contactId, String? displayName}) async =>
      CallStart.fromJson(await _req('POST', '/v1/calls', body: {
        'channel': pstn ? 'pstn' : 'app',
        'callee_user_id': calleeUserId,
        'phone': phone,
        'contact_id': contactId,
        'display_name': displayName,
      }));

  @override
  Future<AcceptResult> acceptCall(String callId) async {
    final j = await _req('POST', '/v1/calls/$callId/accept');
    return (roomUrl: j['room_url'] as String, token: j['token'] as String, recorded: j['recorded'] as bool, disclosure: j['disclosure'] as String?);
  }

  @override
  Future<void> declineCall(String callId) => _req('POST', '/v1/calls/$callId/decline');

  @override
  Future<void> endCall(String callId) => _req('POST', '/v1/calls/$callId/end');

  @override
  Future<CallDetail> callDetail(String callId) async => CallDetail.fromJson(await _req('GET', '/v1/calls/$callId'));

  @override
  Future<CallDetail> submitReview(String callId,
          {required List<String> accept,
          required List<String> reject,
          Map<String, Map<String, dynamic>> edits = const {},
          List<Map<String, dynamic>> add = const []}) async =>
      CallDetail.fromJson(await _req('POST', '/v1/calls/$callId/review',
          body: {'accept': accept, 'reject': reject, 'edits': edits, 'add': add}));

  @override
  Future<List<Commitment>> commitments({bool team = false, String? memberId, String? status}) async => [
        for (final c in await _req('GET', '/v1/commitments', query: {
          'scope': team ? 'team' : 'mine',
          if (memberId != null) 'member_id': memberId,
          if (status != null) 'status': status,
        }))
          Commitment.fromJson(c)
      ];

  @override
  Future<Commitment> updateCommitment(String id, {CommitmentStatus? status, String? title, DateTime? dueAt, String? note}) async =>
      Commitment.fromJson(await _req('PATCH', '/v1/commitments/$id', body: {
        if (status != null) 'status': enumWire(status),
        if (title != null) 'title': title,
        if (dueAt != null) 'due_at': dueAt.toUtc().toIso8601String(),
        if (note != null) 'note': note,
      }));

  @override
  Future<void> comment(String id, String text) => _req('POST', '/v1/commitments/$id/comments', body: {'text': text});

  @override
  Future<void> nudge(String id) => _req('POST', '/v1/commitments/$id/nudge');

  @override
  Future<List<CommitmentEvent>> events(String id) async =>
      [for (final e in await _req('GET', '/v1/commitments/$id/events')) CommitmentEvent.fromJson(e)];

  @override
  Future<Dashboard> dashboard({int days = 30}) async =>
      Dashboard.fromJson(await _req('GET', '/v1/dashboard', query: {'days': '$days'}));

  @override
  Future<void> registerDevice(String platform, String? pushToken) =>
      _req('POST', '/v1/devices', body: {'platform': platform, 'push_token': pushToken});

  @override
  Future<bool> setRecordPersonalCalls(bool on) async =>
      (await _req('PATCH', '/v1/me/settings', body: {'record_personal_calls': on}))['record_personal_calls'] as bool;

  @override
  Future<({int imported, int skipped, int onApp})> importContacts(List<Map<String, dynamic>> contacts) async {
    var imported = 0, skipped = 0, onApp = 0;
    // The server takes up to 5,000 per request; big address books go in chunks.
    for (var i = 0; i < contacts.length; i += 2000) {
      final chunk = contacts.sublist(i, (i + 2000).clamp(0, contacts.length));
      final r = await _req('POST', '/v1/contacts/import', body: {'contacts': chunk, 'default_region': 'NG'});
      imported += r['imported'] as int;
      skipped += r['skipped'] as int;
      onApp += r['on_app'] as int;
    }
    return (imported: imported, skipped: skipped, onApp: onApp);
  }

  @override
  Future<void> reportProblem(String where, String message, {String? callId}) async {
    try {
      await _req('POST', '/v1/diagnostics', body: {'where': where, 'message': message, if (callId != null) 'call_id': callId});
    } catch (_) {
      // Diagnostics must never cause a second error.
    }
  }

  @override
  Future<void> flagMoment(String callId, int offsetMs) => _req('POST', '/v1/calls/$callId/flags', body: {'offset_ms': offsetMs});

  @override
  Future<List<IncomingCall>> ringing() async => [
        for (final j in await _req('GET', '/v1/calls/incoming'))
          IncomingCall(
            callId: j['call_id'] as String,
            callerName: (j['caller_name'] as String?) ?? 'Caller',
            recorded: j['recorded'] == true,
            mode: j['mode'] == 'corporate' ? AppMode.corporate : AppMode.personal,
            roomUrl: j['room_url'] as String?,
          )
      ];

  @override
  Future<void> simulateExtraction(String callId) => _req('POST', '/dev/calls/$callId/simulate');
}
