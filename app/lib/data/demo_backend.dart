import 'dart:async';
import 'dart:math';

import '../models/models.dart';
import 'backend.dart';

/// Fully offline backend: a simulated company (Lumen Logistics), the same
/// routing rules as the server, and a scripted client call whose
/// commitments "the AI" extracts when you hang up.
///
/// Corporate login: code LUMEN · employee EMP-1042 (Ada) or EMP-1001 (Ngozi, manager) · PIN 1234
class DemoBackend extends Backend {
  DemoBackend({required this.persona}) {
    _seed();
  }

  /// 'ada' (employee) or 'ngozi' (manager).
  final String persona;

  static const demoScript = <(String, String)>[
    ('employee', "Good afternoon Mr. Bello, it's Ada from Lumen Logistics. Thanks for picking up."),
    ('client', "Ada, good afternoon. I'm glad you called, the last two deliveries to Kano were late again."),
    ('employee', "I'm sorry about that. I've seen the report and the truck was held at the Kaduna checkpoint."),
    ('client', "I understand, but my customers don't. I need to know this won't keep happening."),
    ('employee', 'Understood. I will send you a written incident report with the root cause by Friday.'),
    ('employee', "And I'll make sure the next three Kano shipments go on our priority lane at no extra cost."),
    ('client', 'That would help. What about the invoice for the late batch?'),
    ('employee', "We'll apply a 10% credit on that invoice, I'll send the revised invoice tomorrow morning."),
    ('client', 'Okay. I will send you the updated delivery schedule for December by end of the week.'),
    ('employee', 'Perfect. Let me also call you back next Tuesday to confirm the priority lane is working.'),
    ('client', 'Thank you Ada, I appreciate you handling this quickly.'),
  ];

  /// Index into [demoScript] → the live hint the bot would push.
  static final demoHints = <int, LiveHint>{
    4: LiveHint(title: 'Send written incident report', dueText: 'by Friday', category: 'deliverable'),
    5: LiveHint(title: 'Priority lane for next 3 Kano shipments', category: 'deliverable'),
    7: LiveHint(title: 'Apply 10% credit, send revised invoice', dueText: 'tomorrow morning', category: 'pricing'),
    9: LiveHint(title: 'Call back to confirm priority lane', dueText: 'next Tuesday', category: 'follow_up'),
  };

  final _rand = Random();
  late final Organization org;
  late final Map<String, Membership> _members; // persona → membership
  final Map<String, String> _memberNames = {};
  AppMode _mode = AppMode.personal;
  bool _corpSessionValid = false;
  final List<Contact> _personalContacts = [];
  final List<Contact> _orgContacts = [];
  final List<CallRecord> _calls = [];
  final Map<String, List<TranscriptLine>> _transcripts = {};
  final List<Commitment> _commitments = [];
  final Map<String, List<CommitmentEvent>> _events = {};
  final List<HeldCall> _held = [];
  int _seq = 0;

  String _id(String p) => '$p-${++_seq}';
  Future<T> _lag<T>(T v, [int ms = 250]) => Future.delayed(Duration(milliseconds: ms + _rand.nextInt(200)), () => v);

  Membership get _me => _members[persona]!;
  String get _myName => persona == 'ada' ? 'Ada Okafor' : 'Ngozi Adeyemi';

  // ------------------------------------------------------------------ seed --
  void _seed() {
    final now = DateTime.now();
    org = Organization(
      id: 'org-lumen',
      name: 'Lumen Logistics',
      corpCode: 'LUMEN',
      disclosure: 'This call is recorded so Lumen Logistics can follow up on everything we agree today.',
    );
    _members = {
      'ngozi': Membership(id: 'm-ngozi', orgId: org.id, employeeId: 'EMP-1001', role: MemberRole.admin, title: 'Head of Sales', department: 'Sales', corporateDid: '+2342013300101'),
      'ada': Membership(id: 'm-ada', orgId: org.id, employeeId: 'EMP-1042', role: MemberRole.employee, title: 'Account Manager', department: 'Sales', corporateDid: '+2342013300142'),
      'tunde': Membership(id: 'm-tunde', orgId: org.id, employeeId: 'EMP-1043', role: MemberRole.employee, title: 'Account Manager', department: 'Sales'),
      'kemi': Membership(id: 'm-kemi', orgId: org.id, employeeId: 'EMP-1077', role: MemberRole.employee, title: 'Customer Success', department: 'Support'),
    };
    _memberNames.addAll({'m-ngozi': 'Ngozi Adeyemi', 'm-ada': 'Ada Okafor', 'm-tunde': 'Tunde Bakare', 'm-kemi': 'Kemi Lawal'});

    _orgContacts.addAll([
      Contact(id: 'c-bello', name: 'Ibrahim Bello', company: 'Bello Foods', phone: '+2348031234567', appUserId: 'u-bello', isClient: true),
      Contact(id: 'c-zenith', name: 'Funke Adeyemi', company: 'Zenith Agro', phone: '+2348059876543', isClient: true),
      Contact(id: 'c-coastal', name: 'Coastal Pharma (front desk)', company: 'Coastal Pharma', phone: '+23412701234', isClient: true),
      Contact(id: 'c-harmattan', name: 'Musa Danjuma', company: 'Harmattan Retail', phone: '+2348120001111', isClient: true),
      Contact(id: 'c-tunde', name: 'Tunde Bakare', company: 'Lumen Logistics', phone: '+2342013300143', appUserId: 'u-tunde'),
    ]);
    _personalContacts.addAll([
      Contact(id: 'p-chidi', name: 'Chidi Nwosu', phone: '+2348090000001', appUserId: 'u-chidi'),
      Contact(id: 'p-mum', name: 'Mum', phone: '+2348030000000'),
      Contact(id: 'p-temi', name: 'Temi (gym)', phone: '+2348091112222', appUserId: 'u-temi'),
    ]);

    // Personal history.
    _calls.addAll([
      _rec('personal', 'Mum', '+2348030000000', CallChannel.pstnMobile, now.subtract(const Duration(hours: 20)), 6),
      _rec('personal', 'Chidi Nwosu', null, CallChannel.app, now.subtract(const Duration(days: 2, hours: 3)), 14, direction: 'inbound'),
    ]);

    // Corporate history for the employee persona.
    final k1 = _rec('corporate', 'Ibrahim Bello', '+2348031234567', CallChannel.pstnMobile, now.subtract(const Duration(hours: 3)), 7,
        contactId: 'c-bello', member: 'm-ada', sentiment: 'mixed', count: 4,
        summary: 'Bello Foods escalated two late Kano deliveries. Ada committed to an incident report, a 10% invoice credit '
            'and priority-lane routing; the client will send December\'s schedule.');
    final k2 = _rec('corporate', 'Funke Adeyemi', '+2348059876543', CallChannel.pstnMobile, now.subtract(const Duration(days: 6)), 12,
        contactId: 'c-zenith', member: 'm-ada', sentiment: 'positive', count: 2,
        summary: 'Zenith Agro wants Q1 cold-chain capacity. Ada promised a proposal and a site visit.');
    final k3 = _rec('corporate', 'Coastal Pharma (front desk)', '+23412701234', CallChannel.pstnLandline, now.subtract(const Duration(days: 2)), 5,
        contactId: 'c-coastal', member: 'm-tunde', sentiment: 'neutral', count: 2,
        summary: 'Coastal Pharma asked for temperature logs on the last consignment.');
    final k4 = _rec('corporate', 'Musa Danjuma', null, CallChannel.app, now.subtract(const Duration(days: 1)), 9,
        contactId: 'c-harmattan', member: 'm-kemi', sentiment: 'negative', count: 2, direction: 'inbound',
        summary: 'Harmattan Retail reported a damaged pallet; client frustrated about slow claims.');
    _calls.addAll([k1, k2, k3, k4]);
    _transcripts[k1.id] = [
      for (var i = 0; i < demoScript.length; i++)
        TranscriptLine(speaker: demoScript[i].$1, text: demoScript[i].$2, offsetMs: i * 21000)
    ];

    Commitment c(String member, String? call, String client, String title, String? quote, DateTime? due,
        CommitmentStatus status, String category,
        {String priority = 'medium', String owner = 'employee', double conf = 0.9, DateTime? done, int createdDaysAgo = 3, String? dueText}) {
      final row = Commitment(
        id: _id('cm'),
        title: title,
        status: status,
        owner: owner,
        category: category,
        priority: priority,
        confidence: conf,
        createdAt: now.subtract(Duration(days: createdDaysAgo)),
        callId: call,
        clientName: client,
        quote: quote,
        quoteOffsetMs: 84000,
        dueAt: due,
        dueText: dueText,
        employeeName: _memberNames[member],
        membershipId: member,
        completedAt: done,
      );
      _commitments.add(row);
      _events[row.id] = [CommitmentEvent(kind: 'created', actorName: 'Commit Call', at: row.createdAt, payload: {})];
      return row;
    }

    c('m-ada', k1.id, 'Bello Foods', 'Send written incident report with root cause',
        'I will send you a written incident report with the root cause by Friday.', now.add(const Duration(days: 2)),
        CommitmentStatus.open, 'deliverable', priority: 'high', createdDaysAgo: 0, dueText: 'by Friday');
    c('m-ada', k1.id, 'Bello Foods', 'Apply 10% credit and send revised invoice',
        "We'll apply a 10% credit on that invoice, I'll send the revised invoice tomorrow morning.",
        now.add(const Duration(hours: 18)), CommitmentStatus.open, 'pricing', priority: 'high', createdDaysAgo: 0, dueText: 'tomorrow morning');
    c('m-ada', k1.id, 'Bello Foods', 'Route next three Kano shipments on priority lane',
        "I'll make sure the next three Kano shipments go on our priority lane at no extra cost.", null,
        CommitmentStatus.pendingReview, 'deliverable', conf: 0.74, createdDaysAgo: 0);
    c('m-ada', k1.id, 'Bello Foods', 'Send updated December delivery schedule',
        'I will send you the updated delivery schedule for December by end of the week.', now.add(const Duration(days: 3)),
        CommitmentStatus.open, 'deliverable', owner: 'client', createdDaysAgo: 0, dueText: 'end of the week');
    c('m-ada', k2.id, 'Zenith Agro', 'Send Q1 cold-chain capacity proposal',
        "I'll get the cold-chain proposal over to you by Monday.", now.subtract(const Duration(days: 2)),
        CommitmentStatus.missed, 'deliverable', priority: 'high', createdDaysAgo: 6, dueText: 'by Monday');
    c('m-ada', k2.id, 'Zenith Agro', 'Arrange site visit to Ikeja warehouse',
        "We'll set up a visit to the Ikeja warehouse next week.", now.subtract(const Duration(days: 1)),
        CommitmentStatus.fulfilled, 'meeting', done: now.subtract(const Duration(days: 2)), createdDaysAgo: 6);
    c('m-tunde', k3.id, 'Coastal Pharma', 'Email temperature logs for consignment CP-8812',
        "I'll email the temperature logs this afternoon.", now.subtract(const Duration(days: 2)),
        CommitmentStatus.fulfilled, 'information', done: now.subtract(const Duration(days: 2, hours: 2)), createdDaysAgo: 2);
    c('m-tunde', k3.id, 'Coastal Pharma', 'Confirm insurance cover for January shipments',
        'Let me confirm the insurance cover and get back to you tomorrow.', now.subtract(const Duration(hours: 20)),
        CommitmentStatus.missed, 'information', createdDaysAgo: 2, dueText: 'tomorrow');
    c('m-tunde', null, 'Coastal Pharma', 'Share revised 2027 rate card',
        "We'll send the 2027 rate card before the end of the month.", now.add(const Duration(days: 12)),
        CommitmentStatus.inProgress, 'pricing', priority: 'high', createdDaysAgo: 9);
    c('m-kemi', k4.id, 'Harmattan Retail', 'Open damage claim and share claim number',
        "I'll open the claim right after this call and text you the claim number.", now.subtract(const Duration(hours: 22)),
        CommitmentStatus.fulfilled, 'support', priority: 'high', done: now.subtract(const Duration(hours: 23)), createdDaysAgo: 1);
    c('m-kemi', k4.id, 'Harmattan Retail', 'Get claims team decision on damaged pallet',
        "You'll have a decision from the claims team in two days.", now.add(const Duration(hours: 26)),
        CommitmentStatus.open, 'support', priority: 'high', createdDaysAgo: 1, dueText: 'in two days');

    // History so the trend chart and reliability scores have shape.
    const clients = {'m-ada': 'Bello Foods', 'm-tunde': 'Coastal Pharma', 'm-kemi': 'Harmattan Retail'};
    for (var w = 1; w < 8; w++) {
      var j = 0;
      for (final e in clients.entries) {
        for (var n = 0; n < 1 + (w + j) % 3; n++) {
          final created = 7 * w + j;
          final due = now.subtract(Duration(days: created - 3));
          final hit = (w + j + n) % 5 != 0;
          c(e.key, null, e.value, 'Follow-up $w$j$n', null, due,
              hit ? CommitmentStatus.fulfilled : CommitmentStatus.missed, const ['follow_up', 'deliverable', 'information'][n % 3],
              done: hit ? due.subtract(const Duration(hours: 6)) : null, createdDaysAgo: created);
        }
        j++;
      }
    }
  }

  CallRecord _rec(String mode, String name, String? number, CallChannel channel, DateTime start, int minutes,
      {String direction = 'outbound', String? contactId, String? member, String? sentiment, String? summary, int count = 0, String status = 'completed'}) {
    return CallRecord(
      id: _id('call'),
      mode: mode == 'corporate' ? AppMode.corporate : AppMode.personal,
      direction: direction,
      channel: channel,
      status: status,
      counterpartName: name,
      counterpartNumber: number,
      contactId: contactId,
      startedAt: start,
      answeredAt: start.add(const Duration(seconds: 6)),
      endedAt: start.add(Duration(minutes: minutes)),
      summary: summary,
      sentiment: sentiment,
      processing: mode == 'corporate' ? 'done' : 'not_applicable',
      commitmentCount: count,
      membershipId: member,
    );
  }

  // --------------------------------------------------------------- session --
  Session _session() => Session(
        profile: Profile(id: 'u-$persona', fullName: _myName),
        mode: _mode,
        membership: _mode == AppMode.corporate ? _me : null,
        organization: _mode == AppMode.corporate ? org : null,
      );

  @override
  Future<Session> me() => _lag(_session(), 100);

  @override
  Future<CorporateLoginResult> corporateLogin(String corpCode, String employeeId, String pin) async {
    await _lag(null, 700);
    if (corpCode.trim().toUpperCase() != 'LUMEN' || employeeId.trim().toUpperCase() != _me.employeeId || pin != '1234') {
      throw ApiException(401, 'Corporate code, employee ID or PIN is incorrect');
    }
    _mode = AppMode.corporate;
    _corpSessionValid = true;
    return (corpSession: 'demo-corp-session', session: _session(), held: <HeldCall>[]);
  }

  @override
  Future<List<HeldCall>> setMode(AppMode mode, {String? corpSession}) async {
    await _lag(null, 300);
    if (mode == AppMode.corporate) {
      if (!_corpSessionValid || corpSession == null) throw ApiException(401, 'Corporate login required');
      _mode = mode;
      return const [];
    }
    _mode = mode;
    final held = List<HeldCall>.of(_held);
    _held.clear();
    return held;
  }

  // -------------------------------------------------------------- contacts --
  @override
  Future<List<Contact>> contacts() =>
      _lag(List.of(_mode == AppMode.corporate ? _orgContacts : _personalContacts)..sort((a, b) => a.name.compareTo(b.name)), 120);

  @override
  Future<Contact> addContact({required String name, String? company, String? phone, String? email}) async {
    final c = Contact(id: _id('c'), name: name, company: company, phone: phone, isClient: _mode == AppMode.corporate);
    (_mode == AppMode.corporate ? _orgContacts : _personalContacts).add(c);
    return _lag(c);
  }

  // ----------------------------------------------------------------- calls --
  @override
  Future<List<CallRecord>> calls() async {
    final mine = _calls.where((c) {
      if (c.mode != _mode) return false;
      if (c.mode == AppMode.personal) return true;
      return c.membershipId == _me.id;
    }).toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return _lag(mine, 150);
  }

  @override
  Future<CallStart> startCall({bool pstn = false, String? calleeUserId, String? phone, String? contactId, String? displayName}) async {
    await _lag(null, 400);
    final contact = [..._orgContacts, ..._personalContacts].where((c) => c.id == contactId).firstOrNull;
    final corp = _mode == AppMode.corporate;
    final name = displayName ?? contact?.name ?? phone ?? 'Unknown';
    final channel = !pstn ? CallChannel.app : (phone ?? contact?.phone ?? '').startsWith('+2341') ? CallChannel.pstnLandline : CallChannel.pstnMobile;
    final rec = CallRecord(
      id: _id('call'),
      mode: _mode,
      direction: 'outbound',
      channel: channel,
      status: 'ringing',
      counterpartName: name,
      counterpartNumber: phone ?? contact?.phone,
      contactId: contactId,
      startedAt: DateTime.now(),
      processing: corp ? 'pending' : 'not_applicable',
      membershipId: corp ? _me.id : null,
    );
    _calls.add(rec);
    return CallStart(
      call: rec,
      roomUrl: 'demo://room/${rec.id}',
      token: 'demo',
      recorded: corp,
      decision: 'ring',
      disclosure: corp ? org.disclosure : null,
    );
  }

  /// Demo: someone calls you. Applies the same rules as the server.
  /// Returns a message to show when the call was held instead of ringing.
  String? simulateIncoming({required bool fromClient}) {
    final name = fromClient ? 'Ibrahim Bello · Bello Foods' : 'Chidi Nwosu';
    final corporateCall = fromClient;
    if (_mode == AppMode.corporate && !corporateCall) {
      final rec = CallRecord(
        id: _id('call'), mode: AppMode.personal, direction: 'inbound', channel: CallChannel.app,
        status: 'blocked_mode', counterpartName: 'Chidi Nwosu', startedAt: DateTime.now(),
      );
      _calls.add(rec);
      _held.add(HeldCall(from: 'Chidi Nwosu', at: DateTime.now()));
      return 'Chidi tried to call. Held — you\'re in Work mode. You\'ll see it when you switch back.';
    }
    if (_mode == AppMode.personal && corporateCall) {
      final rec = CallRecord(
        id: _id('call'), mode: AppMode.corporate, direction: 'inbound', channel: CallChannel.pstnMobile,
        status: 'off_duty', counterpartName: 'Ibrahim Bello', startedAt: DateTime.now(), membershipId: _me.id,
      );
      _calls.add(rec);
      return 'Bello Foods called your work line. You\'re off duty, so it went to voicemail and your team can see it.';
    }
    final rec = CallRecord(
      id: _id('call'), mode: _mode, direction: 'inbound', channel: CallChannel.app, status: 'ringing',
      counterpartName: name.split(' · ').first, contactId: fromClient ? 'c-bello' : 'p-chidi',
      startedAt: DateTime.now(), membershipId: _mode == AppMode.corporate ? _me.id : null,
      processing: _mode == AppMode.corporate ? 'pending' : 'not_applicable',
    );
    _calls.add(rec);
    incoming.add(IncomingCall(callId: rec.id, callerName: name, recorded: _mode == AppMode.corporate, mode: _mode));
    return null;
  }

  CallRecord _replace(String id, CallRecord Function(CallRecord) f) {
    final i = _calls.indexWhere((c) => c.id == id);
    final updated = f(_calls[i]);
    _calls[i] = updated;
    return updated;
  }

  CallRecord _with(CallRecord c, {String? status, DateTime? answeredAt, DateTime? endedAt, String? summary, String? sentiment, String? processing, int? count}) =>
      CallRecord(
        id: c.id, mode: c.mode, direction: c.direction, channel: c.channel, status: status ?? c.status,
        counterpartName: c.counterpartName, counterpartNumber: c.counterpartNumber, contactId: c.contactId,
        startedAt: c.startedAt, answeredAt: answeredAt ?? c.answeredAt, endedAt: endedAt ?? c.endedAt,
        summary: summary ?? c.summary, sentiment: sentiment ?? c.sentiment, processing: processing ?? c.processing,
        commitmentCount: count ?? c.commitmentCount, membershipId: c.membershipId,
      );

  /// Called by the demo call engine when the far end "answers".
  void markAnswered(String callId) => _replace(callId, (c) => _with(c, status: 'active', answeredAt: DateTime.now()));

  @override
  Future<AcceptResult> acceptCall(String callId) async {
    final c = _replace(callId, (c) => _with(c, status: 'active', answeredAt: DateTime.now()));
    return _lag((roomUrl: 'demo://room/$callId', token: 'demo', recorded: c.mode == AppMode.corporate, disclosure: c.mode == AppMode.corporate ? org.disclosure : null));
  }

  @override
  Future<void> declineCall(String callId) async {
    _replace(callId, (c) => _with(c, status: 'rejected', endedAt: DateTime.now()));
  }

  @override
  Future<void> endCall(String callId) async {
    _replace(callId, (c) => _with(c, status: c.answeredAt != null ? 'completed' : 'missed', endedAt: DateTime.now()));
  }

  @override
  Future<CallDetail> callDetail(String callId) async {
    final call = _calls.firstWhere((c) => c.id == callId);
    return _lag(CallDetail(
      call: call,
      transcript: _transcripts[callId] ?? const [],
      commitments: _commitments.where((c) => c.callId == callId).toList(),
    ));
  }

  /// "AI" extraction for the scripted call (the real one runs server-side).
  @override
  Future<void> simulateExtraction(String callId) async {
    await Future.delayed(const Duration(milliseconds: 1600));
    final call = _calls.firstWhere((c) => c.id == callId);
    if (call.mode != AppMode.corporate) return;
    final heard = (call.length?.inSeconds ?? 0) ~/ 3 + 1;
    final lines = demoScript.take(max(5, min(demoScript.length, heard))).toList();
    _transcripts[callId] = [
      for (var i = 0; i < lines.length; i++) TranscriptLine(speaker: lines[i].$1, text: lines[i].$2, offsetMs: i * 4000)
    ];
    final now = DateTime.now();
    DateTime nextWeekday(int weekday) {
      final days = (weekday - now.weekday) % 7 == 0 ? 7 : (weekday - now.weekday) % 7;
      final d = now.add(Duration(days: days));
      return DateTime(d.year, d.month, d.day, 17);
    }

    final client = _orgContacts.where((c) => c.id == call.contactId).firstOrNull?.company ?? call.counterpartName;
    final found = <Commitment>[
      Commitment(id: _id('cm'), title: 'Send written incident report with root cause', status: CommitmentStatus.pendingReview,
          owner: 'employee', category: 'deliverable', priority: 'high', confidence: 0.93, createdAt: now, callId: callId,
          clientName: client, quote: demoScript[4].$2, quoteOffsetMs: 16000, dueAt: nextWeekday(DateTime.friday), dueText: 'by Friday',
          membershipId: _me.id, employeeName: _myName),
      Commitment(id: _id('cm'), title: 'Route next three Kano shipments on priority lane', status: CommitmentStatus.pendingReview,
          owner: 'employee', category: 'deliverable', priority: 'medium', confidence: 0.74, createdAt: now, callId: callId,
          clientName: client, quote: demoScript[5].$2, quoteOffsetMs: 20000, membershipId: _me.id, employeeName: _myName),
      Commitment(id: _id('cm'), title: 'Apply 10% credit and send revised invoice', status: CommitmentStatus.pendingReview,
          owner: 'employee', category: 'pricing', priority: 'high', confidence: 0.95, createdAt: now, callId: callId,
          clientName: client, quote: demoScript[7].$2, quoteOffsetMs: 28000,
          dueAt: DateTime(now.year, now.month, now.day + 1, 10), dueText: 'tomorrow morning', membershipId: _me.id, employeeName: _myName),
      if (lines.length > 8)
        Commitment(id: _id('cm'), title: 'Send updated December delivery schedule', status: CommitmentStatus.pendingReview,
            owner: 'client', category: 'deliverable', priority: 'medium', confidence: 0.88, createdAt: now, callId: callId,
            clientName: client, quote: demoScript[8].$2, quoteOffsetMs: 32000, dueAt: nextWeekday(DateTime.friday),
            dueText: 'end of the week', membershipId: _me.id, employeeName: _myName),
      if (lines.length > 9)
        Commitment(id: _id('cm'), title: 'Call back to confirm priority lane is working', status: CommitmentStatus.pendingReview,
            owner: 'employee', category: 'follow_up', priority: 'medium', confidence: 0.9, createdAt: now, callId: callId,
            clientName: client, quote: demoScript[9].$2, quoteOffsetMs: 36000, dueAt: nextWeekday(DateTime.tuesday),
            dueText: 'next Tuesday', membershipId: _me.id, employeeName: _myName),
    ];
    for (final c in found) {
      _commitments.add(c);
      _events[c.id] = [CommitmentEvent(kind: 'created', actorName: 'Commit Call', at: now, payload: {})];
    }
    _replace(callId, (c) => _with(c, processing: 'done', count: found.length, sentiment: 'mixed',
        summary: '$client raised late deliveries. You committed to ${found.where((f) => !f.byClient).length} follow-ups '
            'including an invoice credit; the client owes you a schedule.'));
  }

  @override
  Future<CallDetail> submitReview(String callId,
      {required List<String> accept,
      required List<String> reject,
      Map<String, Map<String, dynamic>> edits = const {},
      List<Map<String, dynamic>> add = const []}) async {
    for (final c in _commitments.where((c) => c.callId == callId)) {
      if (accept.contains(c.id)) {
        c.status = CommitmentStatus.open;
        final e = edits[c.id];
        if (e?['title'] != null) c.title = e!['title'];
        if (e?['due_at'] != null) c.dueAt = DateTime.parse(e!['due_at']);
        _events[c.id]!.add(CommitmentEvent(kind: 'confirmed', actorName: _myName, at: DateTime.now(), payload: {}));
      } else if (reject.contains(c.id)) {
        c.status = CommitmentStatus.cancelled;
      }
    }
    for (final a in add) {
      final c = Commitment(id: _id('cm'), title: a['title'], status: CommitmentStatus.open, owner: 'employee',
          category: a['category'] ?? 'other', priority: 'medium', confidence: 1, createdAt: DateTime.now(), callId: callId,
          clientName: _calls.firstWhere((x) => x.id == callId).counterpartName,
          dueAt: a['due_at'] == null ? null : DateTime.parse(a['due_at']), membershipId: _me.id, employeeName: _myName);
      _commitments.add(c);
      _events[c.id] = [CommitmentEvent(kind: 'created', actorName: _myName, at: DateTime.now(), payload: {'manual': true})];
    }
    return callDetail(callId);
  }

  // ----------------------------------------------------------- commitments --
  Set<String> get _visible => _me.isManager ? _members.values.map((m) => m.id).toSet() : {_me.id};

  @override
  Future<List<Commitment>> commitments({bool team = false, String? memberId, String? status}) async {
    if (_mode != AppMode.corporate) throw ApiException(403, 'Switch to Work mode first');
    var ids = team ? _visible : {_me.id};
    if (memberId != null) ids = ids.intersection({memberId});
    final wanted = status?.split(',').toSet();
    const rank = {
      CommitmentStatus.pendingReview: 0, CommitmentStatus.missed: 1, CommitmentStatus.open: 2,
      CommitmentStatus.inProgress: 2, CommitmentStatus.disputed: 3, CommitmentStatus.fulfilled: 5, CommitmentStatus.cancelled: 6,
    };
    final far = DateTime(2100);
    final rows = _commitments
        .where((c) => ids.contains(c.membershipId) && (wanted == null || wanted.contains(enumWire(c.status))))
        .toList()
      ..sort((a, b) {
        final r = rank[a.status]!.compareTo(rank[b.status]!);
        return r != 0 ? r : (a.dueAt ?? far).compareTo(b.dueAt ?? far);
      });
    return _lag(rows, 150);
  }

  @override
  Future<Commitment> updateCommitment(String id, {CommitmentStatus? status, String? title, DateTime? dueAt, String? note}) async {
    final c = _commitments.firstWhere((c) => c.id == id);
    if (status != null && status != c.status) {
      _events[id]!.add(CommitmentEvent(kind: 'status_changed', actorName: _myName, at: DateTime.now(),
          payload: {'from': enumWire(c.status), 'to': enumWire(status), if (note != null) 'note': note}));
      c.status = status;
      if (status == CommitmentStatus.fulfilled) c.completedAt = DateTime.now();
    }
    if (title != null) c.title = title;
    if (dueAt != null) {
      _events[id]!.add(CommitmentEvent(kind: 'due_changed', actorName: _myName, at: DateTime.now(), payload: {}));
      c.dueAt = dueAt;
    }
    return _lag(c);
  }

  @override
  Future<void> comment(String id, String text) async {
    _events[id]!.add(CommitmentEvent(kind: 'comment', actorName: _myName, at: DateTime.now(), payload: {'text': text}));
  }

  @override
  Future<void> nudge(String id) async {
    _events[id]!.add(CommitmentEvent(kind: 'nudge', actorName: _myName, at: DateTime.now(), payload: {}));
    await _lag(null);
  }

  @override
  Future<List<CommitmentEvent>> events(String id) => _lag(List.of(_events[id] ?? const []), 100);

  // ------------------------------------------------------------- dashboard --
  @override
  Future<Dashboard> dashboard({int days = 30}) async {
    if (!_me.isManager) throw ApiException(403, 'Managers only');
    final now = DateTime.now();
    final since = now.subtract(Duration(days: days));
    final rows = _commitments.where((c) => !c.byClient).toList();
    final live = rows.where((c) => c.isLive).toList();
    bool onTime(Commitment c) => c.status == CommitmentStatus.fulfilled && (c.dueAt == null || !c.completedAt!.isAfter(c.dueAt!));
    final closed = rows.where((c) => (c.status == CommitmentStatus.fulfilled || c.status == CommitmentStatus.missed) && (c.dueAt ?? now).isAfter(since)).toList();
    final calls = _calls.where((c) => c.mode == AppMode.corporate && c.startedAt.isAfter(since)).toList();

    final trend = <WeekPoint>[];
    for (var w = 7; w >= 0; w--) {
      final start = now.subtract(Duration(days: 7 * (w + 1)));
      final end = now.subtract(Duration(days: 7 * w));
      bool inWeek(DateTime? d) => d != null && !d.isBefore(start) && d.isBefore(end);
      trend.add(WeekPoint(
        start,
        rows.where((c) => inWeek(c.createdAt)).length,
        rows.where((c) => c.status == CommitmentStatus.fulfilled && inWeek(c.completedAt)).length,
        rows.where((c) => c.status == CommitmentStatus.missed && inWeek(c.dueAt)).length,
      ));
    }

    final people = <PersonStats>[];
    for (final m in _members.values) {
      final mine = rows.where((c) => c.membershipId == m.id).toList();
      final done = mine.where((c) => c.status == CommitmentStatus.fulfilled || c.status == CommitmentStatus.missed).toList();
      people.add(PersonStats(
        membershipId: m.id,
        name: _memberNames[m.id]!,
        title: m.title,
        open: mine.where((c) => c.isLive).length,
        overdue: mine.where((c) => c.isOverdue).length,
        pendingReview: mine.where((c) => c.status == CommitmentStatus.pendingReview).length,
        reliability: done.isEmpty ? null : (100 * done.where(onTime).length / done.length).round(),
        calls: calls.where((c) => c.membershipId == m.id).length,
      ));
    }
    people.sort((a, b) => b.overdue != a.overdue ? b.overdue - a.overdue : (a.reliability ?? 0) - (b.reliability ?? 0));

    final atRisk = [
      ...live.where((c) => c.dueAt != null && c.dueAt!.isBefore(now.add(const Duration(hours: 48)))),
      ...rows.where((c) => c.status == CommitmentStatus.missed && (c.dueAt ?? now).isAfter(now.subtract(const Duration(days: 7)))),
    ]..sort((a, b) => (a.dueAt ?? now).compareTo(b.dueAt ?? now));

    final cats = <String, int>{};
    for (final c in live) {
      cats[c.category] = (cats[c.category] ?? 0) + 1;
    }

    return _lag(Dashboard(
      kpis: {
        'open': live.length,
        'due_this_week': live.where((c) => c.dueAt != null && c.dueAt!.isAfter(now) && c.dueAt!.isBefore(now.add(const Duration(days: 7)))).length,
        'overdue': rows.where((c) => c.isOverdue && (c.dueAt ?? now).isAfter(since)).length,
        'pending_review': rows.where((c) => c.status == CommitmentStatus.pendingReview).length,
        'on_time_rate': closed.isEmpty ? null : (100 * closed.where(onTime).length / closed.length).round(),
        'calls': calls.length,
        'commitments_per_call': calls.isEmpty ? 0 : (rows.where((c) => c.callId != null && c.createdAt.isAfter(since)).length / calls.length * 10).round() / 10,
        'off_duty_attempts': calls.where((c) => c.status == 'off_duty').length,
      },
      trend: trend,
      byCategory: cats,
      people: people,
      atRisk: atRisk.take(15).toList(),
      attentionCalls: calls.where((c) => c.sentiment == 'negative' || c.sentiment == 'mixed').take(5).toList(),
    ), 300);
  }

  @override
  Future<void> registerDevice(String platform, String? pushToken) async {}
}
