// Plain data classes mirroring the API (snake_case JSON).

enum AppMode { personal, corporate }

enum MemberRole { employee, manager, admin }

enum CommitmentStatus { pendingReview, open, inProgress, fulfilled, missed, disputed, cancelled }

enum CallChannel { app, pstnMobile, pstnLandline, sip }

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v as String);
double? _num(dynamic v) => v == null ? null : (v as num).toDouble();

String _snake(String camel) => camel.replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}');

T _enum<T extends Enum>(List<T> values, dynamic raw, T fallback) {
  for (final v in values) {
    if (_snake(v.name) == raw) return v;
  }
  return fallback;
}

String enumWire(Enum e) => _snake(e.name);

class Profile {
  Profile({required this.id, required this.fullName, this.recordPersonalCalls = true, this.discoverable = true});
  final String id;
  final String fullName;

  /// Personal calls are recorded for the user's own commitments (private to them) unless switched off.
  bool recordPersonalCalls;

  /// Others can find this user by name in "On Commit AI" search.
  bool discoverable;

  factory Profile.fromJson(Map<String, dynamic> j) =>
      Profile(
        id: j['id'],
        fullName: j['full_name'] ?? '',
        recordPersonalCalls: j['record_personal_calls'] ?? true,
        discoverable: j['discoverable'] ?? true,
      );
}

/// Someone with a Commit AI account, found by search. App calls to them are free.
class PlatformUser {
  PlatformUser({required this.userId, required this.fullName, this.emailHint, this.contactId});
  final String userId;
  final String fullName;
  final String? emailHint;
  final String? contactId;

  factory PlatformUser.fromJson(Map<String, dynamic> j) => PlatformUser(
        userId: j['user_id'],
        fullName: j['full_name'] ?? 'Commit AI user',
        emailHint: j['email_hint'],
        contactId: j['contact_id'],
      );
}

class Organization {
  Organization({required this.id, required this.name, required this.corpCode, this.disclosure, this.timezone = 'Africa/Lagos'});
  final String id;
  final String name;
  final String corpCode;
  final String? disclosure;
  final String timezone;

  factory Organization.fromJson(Map<String, dynamic> j) => Organization(
        id: j['id'],
        name: j['name'],
        corpCode: j['corp_code'] ?? '',
        disclosure: j['recording_disclosure'],
        timezone: j['timezone'] ?? 'Africa/Lagos',
      );
}

class Membership {
  Membership({
    required this.id,
    required this.orgId,
    required this.employeeId,
    required this.role,
    this.title,
    this.department,
    this.corporateDid,
    this.mustChangePin = false,
  });
  final String id;
  final String orgId;
  final String employeeId;
  final MemberRole role;
  final String? title;
  final String? department;
  final String? corporateDid;

  /// Signed in with a one-time PIN from the admin: must choose their own.
  bool mustChangePin;

  bool get isAdmin => role == MemberRole.admin;

  bool get isManager => role != MemberRole.employee;

  factory Membership.fromJson(Map<String, dynamic> j) => Membership(
        id: j['id'],
        orgId: j['org_id'],
        employeeId: j['employee_id'],
        role: _enum(MemberRole.values, j['role'], MemberRole.employee),
        title: j['title'],
        department: j['department'],
        corporateDid: j['corporate_did'],
        mustChangePin: j['must_change_pin'] ?? false,
      );
}

/// Someone on the company's team, as the admin manages them.
class OrgMember {
  OrgMember({
    required this.id,
    required this.employeeId,
    required this.role,
    required this.fullName,
    this.email,
    this.title,
    this.department,
    this.managerId,
    this.managerName,
    this.active = true,
    this.joined = false,
    this.mustChangePin = false,
  });
  final String id;
  final String employeeId;
  final MemberRole role;
  final String fullName;
  final String? email;
  final String? title;
  final String? department;
  final String? managerId;
  final String? managerName;
  final bool active;
  final bool joined;
  final bool mustChangePin;

  factory OrgMember.fromJson(Map<String, dynamic> j) => OrgMember(
        id: j['id'],
        employeeId: j['employee_id'] ?? '',
        role: _enum(MemberRole.values, j['role'], MemberRole.employee),
        fullName: j['full_name'] ?? j['employee_id'] ?? '',
        email: j['email'],
        title: j['title'],
        department: j['department'],
        managerId: j['manager_id'],
        managerName: j['manager_name'],
        active: j['active'] ?? true,
        joined: j['joined'] ?? false,
        mustChangePin: j['must_change_pin'] ?? false,
      );
}

/// What an employee needs to sign in for the first time: shown once to the admin to pass on.
class MemberCredentials {
  MemberCredentials({required this.member, required this.corpCode, required this.tempPin});
  final OrgMember member;
  final String corpCode;
  final String tempPin;

  String get shareText => 'You\'ve been added to Commit AI.\n'
      '1. Install Commit AI and create your account${member.email != null ? ' with ${member.email}' : ''}.\n'
      '2. Tap Work and sign in with:\n'
      '   Company code: $corpCode\n'
      '   Employee ID: ${member.employeeId}\n'
      '   One-time PIN: $tempPin\n'
      'You\'ll choose your own PIN after signing in.';
}

/// A company that added this user's email and is waiting for them to join.
class OrgInvite {
  OrgInvite({required this.membershipId, required this.organization, required this.employeeId, required this.role, this.title});
  final String membershipId;
  final String organization;
  final String employeeId;
  final MemberRole role;
  final String? title;

  factory OrgInvite.fromJson(Map<String, dynamic> j) => OrgInvite(
        membershipId: j['membership_id'],
        organization: j['organization'] ?? '',
        employeeId: j['employee_id'] ?? '',
        role: _enum(MemberRole.values, j['role'], MemberRole.employee),
        title: j['title'],
      );
}

/// Company settings and head-count, for the admin screen.
class OrgOverview {
  OrgOverview({required this.org, required this.members, required this.joined, required this.offDutyRings, required this.announce});
  final Organization org;
  final int members;
  final int joined;
  final bool offDutyRings;
  final bool announce;

  factory OrgOverview.fromJson(Map<String, dynamic> j) => OrgOverview(
        org: Organization.fromJson(j['organization']),
        members: (j['counts']?['members'] ?? 0) as int,
        joined: (j['counts']?['joined'] ?? 0) as int,
        offDutyRings: j['organization']['off_duty_policy'] == 'ring',
        announce: j['organization']['announce_recording'] ?? true,
      );
}

class Contact {
  Contact({required this.id, required this.name, this.company, this.phone, this.appUserId, this.isClient = false});
  final String id;
  final String name;
  final String? company;
  final String? phone;
  final String? appUserId;
  final bool isClient;

  bool get onApp => appUserId != null;

  factory Contact.fromJson(Map<String, dynamic> j) => Contact(
        id: j['id'],
        name: j['name'],
        company: j['company'],
        phone: j['phone_e164'],
        appUserId: j['app_user_id'],
        isClient: j['is_client'] ?? false,
      );
}

class CallRecord {
  CallRecord({
    required this.id,
    required this.mode,
    required this.direction,
    required this.channel,
    required this.status,
    required this.counterpartName,
    required this.startedAt,
    this.counterpartNumber,
    this.contactId,
    this.counterpartUserId,
    this.answeredAt,
    this.endedAt,
    this.summary,
    this.sentiment,
    this.processing,
    this.commitmentCount = 0,
    this.membershipId,
  });

  final String id;
  final AppMode mode;
  final String direction; // inbound | outbound
  final CallChannel channel;
  final String status; // ringing active completed missed rejected blocked_mode off_duty failed
  final String counterpartName;
  final String? counterpartNumber;
  final String? contactId;

  /// The other person's Commit AI account, for app calls (call back from Recents).
  final String? counterpartUserId;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;
  final String? summary;
  final String? sentiment;
  final String? processing;
  final int commitmentCount;
  final String? membershipId;

  Duration? get length =>
      answeredAt != null && endedAt != null ? endedAt!.difference(answeredAt!) : null;
  bool get missed => const {'missed', 'rejected', 'blocked_mode', 'off_duty'}.contains(status);
  bool get held => status == 'blocked_mode';

  factory CallRecord.fromJson(Map<String, dynamic> j) => CallRecord(
        id: j['id'],
        mode: j['mode'] == 'corporate' ? AppMode.corporate : AppMode.personal,
        direction: j['direction'] ?? 'outbound',
        channel: _enum(CallChannel.values, j['channel'], CallChannel.app),
        status: j['status'] ?? 'completed',
        counterpartName: j['counterpart_name'] ?? 'Unknown',
        counterpartNumber: j['counterpart_number'],
        contactId: j['contact_id'],
        counterpartUserId: j['counterpart_user_id'],
        startedAt: _dt(j['started_at']) ?? DateTime.now(),
        answeredAt: _dt(j['answered_at']),
        endedAt: _dt(j['ended_at']),
        summary: j['summary'],
        sentiment: j['sentiment'],
        processing: j['processing'],
        commitmentCount: j['commitment_count'] ?? 0,
        membershipId: j['membership_id'],
      );
}

class TranscriptLine {
  TranscriptLine({required this.speaker, required this.text, required this.offsetMs});
  final String speaker; // employee | client | unknown
  final String text;
  final int offsetMs;

  factory TranscriptLine.fromJson(Map<String, dynamic> j) =>
      TranscriptLine(speaker: j['speaker'], text: j['text'], offsetMs: j['offset_ms'] ?? 0);
}

class Commitment {
  Commitment({
    required this.id,
    required this.title,
    required this.status,
    required this.owner,
    required this.category,
    required this.priority,
    required this.confidence,
    required this.createdAt,
    this.callId,
    this.clientName,
    this.quote,
    this.quoteOffsetMs,
    this.dueAt,
    this.dueText,
    this.detail,
    this.employeeName,
    this.membershipId,
    this.completedAt,
  });

  final String id;
  String title;
  CommitmentStatus status;
  final String owner; // employee | client
  String category;
  final String priority;
  final double confidence;
  final DateTime createdAt;
  final String? callId;
  final String? clientName;
  final String? quote;
  final int? quoteOffsetMs;
  DateTime? dueAt;
  final String? dueText;
  final String? detail;
  final String? employeeName;
  final String? membershipId;
  DateTime? completedAt;

  bool get byClient => owner == 'client';
  bool get isLive => status == CommitmentStatus.open || status == CommitmentStatus.inProgress;
  bool get isOverdue =>
      status == CommitmentStatus.missed || (isLive && dueAt != null && dueAt!.isBefore(DateTime.now()));

  factory Commitment.fromJson(Map<String, dynamic> j) => Commitment(
        id: j['id'],
        title: j['title'],
        status: _enum(CommitmentStatus.values, j['status'], CommitmentStatus.open),
        owner: j['owner'] ?? 'employee',
        category: j['category'] ?? 'other',
        priority: j['priority'] ?? 'medium',
        confidence: _num(j['confidence']) ?? 0.8,
        createdAt: _dt(j['created_at']) ?? DateTime.now(),
        callId: j['call_id'],
        clientName: j['client_name'],
        quote: j['quote'],
        quoteOffsetMs: j['quote_offset_ms'],
        dueAt: _dt(j['due_at']),
        dueText: j['due_text'],
        detail: j['detail'],
        employeeName: j['employee_name'],
        membershipId: j['membership_id'],
        completedAt: _dt(j['completed_at']),
      );
}

class CommitmentEvent {
  CommitmentEvent({required this.kind, required this.actorName, required this.at, required this.payload});
  final String kind;
  final String actorName;
  final DateTime at;
  final Map<String, dynamic> payload;

  factory CommitmentEvent.fromJson(Map<String, dynamic> j) => CommitmentEvent(
        kind: j['kind'],
        actorName: j['actor_name'] ?? 'Commit AI',
        at: _dt(j['created_at']) ?? DateTime.now(),
        payload: Map<String, dynamic>.from(j['payload'] ?? const {}),
      );
}

class CallDetail {
  CallDetail({required this.call, required this.transcript, required this.commitments});
  final CallRecord call;
  final List<TranscriptLine> transcript;
  final List<Commitment> commitments;

  factory CallDetail.fromJson(Map<String, dynamic> j) => CallDetail(
        call: CallRecord.fromJson(j['call']),
        transcript: [for (final t in j['transcript'] as List) TranscriptLine.fromJson(t)],
        commitments: [for (final c in j['commitments'] as List) Commitment.fromJson(c)],
      );
}

/// What the server says when you place a call.
class CallStart {
  CallStart({
    required this.call,
    required this.roomUrl,
    required this.token,
    required this.recorded,
    required this.decision,
    this.disclosure,
    this.message,
  });
  final CallRecord call;
  final String roomUrl;
  final String token;
  final bool recorded;
  final String decision; // ring | blocked_mode | off_duty
  final String? disclosure;
  final String? message;

  factory CallStart.fromJson(Map<String, dynamic> j) => CallStart(
        call: CallRecord.fromJson(j['call']),
        roomUrl: j['room_url'] ?? '',
        token: j['token'] ?? '',
        recorded: j['recorded'] ?? false,
        decision: j['decision'] ?? 'ring',
        disclosure: j['disclosure'],
        message: j['message'],
      );
}

class HeldCall {
  HeldCall({required this.from, required this.at});
  final String from;
  final DateTime at;

  factory HeldCall.fromJson(Map<String, dynamic> j) =>
      HeldCall(from: j['from'] ?? 'Someone', at: _dt(j['at']) ?? DateTime.now());
}

/// A "commitment detected" hint pushed by the bot during a call.
class LiveHint {
  LiveHint({required this.title, this.dueText, this.category = 'other', this.quote});
  final String title;
  final String? dueText;
  final String category;
  final String? quote;

  factory LiveHint.fromJson(Map<String, dynamic> j) =>
      LiveHint(title: j['title'], dueText: j['due_text'], category: j['category'] ?? 'other', quote: j['quote']);
}

class PersonStats {
  PersonStats({
    required this.membershipId,
    required this.name,
    this.title,
    required this.open,
    required this.overdue,
    required this.pendingReview,
    this.reliability,
    required this.calls,
  });
  final String membershipId;
  final String name;
  final String? title;
  final int open;
  final int overdue;
  final int pendingReview;
  final int? reliability;
  final int calls;

  factory PersonStats.fromJson(Map<String, dynamic> j) => PersonStats(
        membershipId: j['membership_id'],
        name: j['name'],
        title: j['title'],
        open: j['open'] ?? 0,
        overdue: j['overdue'] ?? 0,
        pendingReview: j['pending_review'] ?? 0,
        reliability: j['reliability'],
        calls: j['calls'] ?? 0,
      );
}

class WeekPoint {
  WeekPoint(this.weekStart, this.made, this.kept, this.missed);
  final DateTime weekStart;
  final int made;
  final int kept;
  final int missed;
}

class Dashboard {
  Dashboard({
    required this.kpis,
    required this.trend,
    required this.byCategory,
    required this.people,
    required this.atRisk,
    required this.attentionCalls,
  });
  final Map<String, num?> kpis;
  final List<WeekPoint> trend;
  final Map<String, int> byCategory;
  final List<PersonStats> people;
  final List<Commitment> atRisk;
  final List<CallRecord> attentionCalls;

  factory Dashboard.fromJson(Map<String, dynamic> j) => Dashboard(
        kpis: Map<String, num?>.from(j['kpis']),
        trend: [
          for (final w in j['trend'] as List)
            WeekPoint(DateTime.parse(w['week_start']), w['made'], w['kept'], w['missed'])
        ],
        byCategory: Map<String, int>.from(j['by_category'] ?? const {}),
        people: [for (final p in j['people'] as List) PersonStats.fromJson(p)],
        atRisk: [for (final c in j['at_risk'] as List) Commitment.fromJson(c)],
        attentionCalls: [for (final c in j['attention_calls'] as List) CallRecord.fromJson(c)],
      );
}

/// Snapshot of who I am right now.
class Session {
  Session({required this.profile, required this.mode, this.membership, this.organization});
  final Profile profile;
  final AppMode mode;
  final Membership? membership;
  final Organization? organization;
}
