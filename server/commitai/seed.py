"""Demo company for the in-memory store: Lumen Logistics (corporate code LUMEN, PIN 1234)."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from .auth import hash_pin

ORG = "11111111-1111-4111-a111-111111111111"
ADA, TUNDE, KEMI, NGOZI, CHIDI, BELLO = (f"00000000-0000-4000-a000-00000000000{i}" for i in range(1, 7))
M_ADA, M_TUNDE, M_KEMI, M_NGOZI = (f"22222222-2222-4222-a222-00000000000{i}" for i in range(1, 5))
C_BELLO, C_ZENITH, C_COASTAL, C_HARMATTAN = (f"33333333-3333-4333-a333-00000000000{i}" for i in range(1, 5))

DEMO_TRANSCRIPT = [
    ("employee", "Good afternoon Mr. Bello, it's Ada from Lumen Logistics. Thanks for picking up."),
    ("client", "Ada, good afternoon. I'm glad you called, the last two deliveries to Kano were late again."),
    ("employee", "I'm sorry about that. I've seen the report and the truck was held at the Kaduna checkpoint."),
    ("client", "I understand, but my customers don't. I need to know this won't keep happening."),
    ("employee", "Understood. I will send you a written incident report with the root cause by Friday."),
    ("employee", "And I'll make sure the next three Kano shipments go on our priority lane at no extra cost."),
    ("client", "That would help. What about the invoice for the late batch?"),
    ("employee", "We'll apply a 10% credit on that invoice, I'll send the revised invoice tomorrow morning."),
    ("client", "Okay. I will send you the updated delivery schedule for December by end of the week."),
    ("employee", "Perfect. Let me also call you back next Tuesday to confirm the priority lane is working."),
    ("client", "Thank you Ada, I appreciate you handling this quickly."),
]


def seed_memory_store(store) -> None:  # noqa: C901 — linear seed data
    now = datetime.now(timezone.utc)
    pin = hash_pin("1234")
    t = store.tables

    def iso(dt: datetime) -> str:
        return dt.isoformat()

    t["organizations"] = [{
        "id": ORG, "name": "Lumen Logistics", "corp_code": "LUMEN", "timezone": "Africa/Lagos",
        "recording_disclosure": "This call is recorded so Lumen Logistics can follow up on everything we agree today.",
        "announce_recording": True, "off_duty_policy": "voicemail", "retention_days": 365,
    }]
    t["profiles"] = [
        {"id": ADA, "full_name": "Ada Okafor"}, {"id": TUNDE, "full_name": "Tunde Bakare"},
        {"id": KEMI, "full_name": "Kemi Lawal"}, {"id": NGOZI, "full_name": "Ngozi Adeyemi"},
        {"id": CHIDI, "full_name": "Chidi Nwosu", "email": "chidi@example.com"}, {"id": BELLO, "full_name": "Ibrahim Bello"},
    ]
    t["memberships"] = [
        {"id": M_NGOZI, "org_id": ORG, "user_id": NGOZI, "employee_id": "EMP-1001", "pin_hash": pin,
         "role": "admin", "title": "Head of Sales", "department": "Sales", "manager_id": None,
         "corporate_did": "+2342013300101", "active": True},
        {"id": M_ADA, "org_id": ORG, "user_id": ADA, "employee_id": "EMP-1042", "pin_hash": pin,
         "role": "employee", "title": "Account Manager", "department": "Sales", "manager_id": M_NGOZI,
         "corporate_did": "+2342013300142", "active": True},
        {"id": M_TUNDE, "org_id": ORG, "user_id": TUNDE, "employee_id": "EMP-1043", "pin_hash": pin,
         "role": "employee", "title": "Account Manager", "department": "Sales", "manager_id": M_NGOZI,
         "corporate_did": "+2342013300143", "active": True},
        {"id": M_KEMI, "org_id": ORG, "user_id": KEMI, "employee_id": "EMP-1077", "pin_hash": pin,
         "role": "employee", "title": "Customer Success", "department": "Support", "manager_id": M_NGOZI,
         "corporate_did": "+2342013300177", "active": True},
    ]
    t["presence"] = [{"user_id": u, "mode": "personal", "membership_id": None} for u in (ADA, TUNDE, KEMI, NGOZI, CHIDI, BELLO)]
    t["devices"] = []
    t["contacts"] = [
        {"id": C_BELLO, "org_id": ORG, "owner_id": ADA, "name": "Ibrahim Bello", "company": "Bello Foods",
         "phone_e164": "+2348031234567", "app_user_id": BELLO, "is_client": True},
        {"id": C_ZENITH, "org_id": ORG, "owner_id": ADA, "name": "Funke Adeyemi", "company": "Zenith Agro",
         "phone_e164": "+2348059876543", "app_user_id": None, "is_client": True},
        {"id": C_COASTAL, "org_id": ORG, "owner_id": TUNDE, "name": "Coastal Pharma (front desk)", "company": "Coastal Pharma",
         "phone_e164": "+23412701234", "app_user_id": None, "is_client": True},
        {"id": C_HARMATTAN, "org_id": ORG, "owner_id": KEMI, "name": "Musa Danjuma", "company": "Harmattan Retail",
         "phone_e164": "+2348120001111", "app_user_id": None, "is_client": True},
        {"id": "33333333-3333-4333-a333-000000000009", "org_id": None, "owner_id": ADA, "name": "Chidi Nwosu",
         "company": None, "phone_e164": "+2348090000001", "app_user_id": CHIDI, "is_client": False},
        {"id": "33333333-3333-4333-a333-000000000010", "org_id": None, "owner_id": ADA, "name": "Mum",
         "company": None, "phone_e164": "+2348030000000", "app_user_id": None, "is_client": False},
    ]

    calls, segs, commits = [], [], []

    def call(cid, member, user, contact, name, number, channel, days_ago, minutes, sentiment, summary, direction="outbound"):
        start = now - timedelta(days=days_ago, hours=2)
        calls.append({
            "id": cid, "org_id": ORG, "mode": "corporate", "user_id": user, "membership_id": member,
            "direction": direction, "channel": channel, "contact_id": contact, "counterpart_name": name,
            "counterpart_number": number, "counterpart_user_id": None, "daily_room": f"commit-seed-{cid[-4:]}",
            "status": "completed", "started_at": iso(start), "answered_at": iso(start + timedelta(seconds=8)),
            "ended_at": iso(start + timedelta(minutes=minutes)), "duration_s": minutes * 60,
            "recording_id": None, "consent_announced": True, "processing": "done", "summary": summary,
            "sentiment": sentiment, "employee_talk_ratio": 0.52, "created_at": iso(start),
        })
        return start

    def commit(member, call_id, contact, client, title, quote, due, status, category, priority="medium",
               owner="employee", confidence=0.9, completed=None, created_days_ago=3, due_text=None):
        created = now - timedelta(days=created_days_ago)
        commits.append({
            "org_id": ORG, "call_id": call_id, "membership_id": member, "contact_id": contact,
            "client_name": client, "owner": owner, "title": title, "detail": None, "quote": quote,
            "quote_offset_ms": 42000, "due_at": iso(due) if due else None, "due_text": due_text,
            "category": category, "priority": priority, "confidence": confidence, "status": status,
            "confirmed_by_employee": status != "pending_review",
            "completed_at": iso(completed) if completed else None, "created_at": iso(created),
        })

    k1 = "44444444-4444-4444-a444-000000000001"
    s1 = call(k1, M_ADA, ADA, C_BELLO, "Ibrahim Bello", "+2348031234567", "pstn_mobile", 0, 7, "mixed",
              "Bello Foods escalated two late Kano deliveries. Ada committed to an incident report, a 10% invoice "
              "credit and priority-lane routing; the client will send December's schedule. Relationship at risk but "
              "recoverable.")
    for i, (sp, text) in enumerate(DEMO_TRANSCRIPT):
        segs.append({"call_id": k1, "speaker": sp, "text": text, "offset_ms": i * 21000})
    commit(M_ADA, k1, C_BELLO, "Bello Foods", "Send written incident report with root cause",
           "I will send you a written incident report with the root cause by Friday.",
           now + timedelta(days=2), "open", "deliverable", "high", created_days_ago=0, due_text="by Friday")
    commit(M_ADA, k1, C_BELLO, "Bello Foods", "Apply 10% credit and send revised invoice",
           "We'll apply a 10% credit on that invoice, I'll send the revised invoice tomorrow morning.",
           now + timedelta(hours=18), "open", "pricing", "high", created_days_ago=0, due_text="tomorrow morning")
    commit(M_ADA, k1, C_BELLO, "Bello Foods", "Route next three Kano shipments on priority lane",
           "I'll make sure the next three Kano shipments go on our priority lane at no extra cost.",
           None, "pending_review", "deliverable", confidence=0.74, created_days_ago=0)
    commit(M_ADA, k1, C_BELLO, "Bello Foods", "Call back to confirm priority lane is working",
           "Let me also call you back next Tuesday to confirm the priority lane is working.",
           now + timedelta(days=7), "open", "follow_up", created_days_ago=0, due_text="next Tuesday")
    commit(M_ADA, k1, C_BELLO, "Bello Foods", "Send updated December delivery schedule",
           "I will send you the updated delivery schedule for December by end of the week.",
           now + timedelta(days=3), "open", "deliverable", owner="client", created_days_ago=0, due_text="end of the week")

    k2 = "44444444-4444-4444-a444-000000000002"
    call(k2, M_ADA, ADA, C_ZENITH, "Funke Adeyemi", "+2348059876543", "pstn_mobile", 6, 12, "positive",
         "Zenith Agro wants cold-chain capacity for Q1. Ada promised a proposal and a site visit.")
    commit(M_ADA, k2, C_ZENITH, "Zenith Agro", "Send Q1 cold-chain capacity proposal",
           "I'll get the cold-chain proposal over to you by Monday.", now - timedelta(days=2), "missed",
           "deliverable", "high", created_days_ago=6, due_text="by Monday")
    commit(M_ADA, k2, C_ZENITH, "Zenith Agro", "Arrange site visit to Ikeja warehouse",
           "We'll set up a visit to the Ikeja warehouse next week.", now - timedelta(days=1), "fulfilled",
           "meeting", completed=now - timedelta(days=2), created_days_ago=6)

    k3 = "44444444-4444-4444-a444-000000000003"
    call(k3, M_TUNDE, TUNDE, C_COASTAL, "Coastal Pharma (front desk)", "+23412701234", "pstn_landline", 2, 5, "neutral",
         "Coastal Pharma asked for temperature logs on the last consignment.")
    commit(M_TUNDE, k3, C_COASTAL, "Coastal Pharma", "Email temperature logs for consignment CP-8812",
           "I'll email the temperature logs this afternoon.", now - timedelta(days=2, hours=-4), "fulfilled",
           "information", completed=now - timedelta(days=2, hours=-2), created_days_ago=2, due_text="this afternoon")
    commit(M_TUNDE, k3, C_COASTAL, "Coastal Pharma", "Confirm insurance cover for January shipments",
           "Let me confirm the insurance cover and get back to you tomorrow.", now - timedelta(hours=20), "missed",
           "information", "medium", created_days_ago=2, due_text="tomorrow")
    commit(M_TUNDE, None, C_COASTAL, "Coastal Pharma", "Share revised rate card for 2027",
           "We'll send the 2027 rate card before the end of the month.", now + timedelta(days=12), "in_progress",
           "pricing", "high", created_days_ago=9)

    k4 = "44444444-4444-4444-a444-000000000004"
    call(k4, M_KEMI, KEMI, C_HARMATTAN, "Musa Danjuma", "+2348120001111", "app", 1, 9, "negative",
         "Harmattan Retail reported a damaged pallet; client frustrated about slow claims.", direction="inbound")
    commit(M_KEMI, k4, C_HARMATTAN, "Harmattan Retail", "Open damage claim and share claim number",
           "I'll open the claim right after this call and text you the claim number.", now - timedelta(days=1, hours=-2),
           "fulfilled", "support", "high", completed=now - timedelta(days=1, hours=-1), created_days_ago=1)
    commit(M_KEMI, k4, C_HARMATTAN, "Harmattan Retail", "Get claims team decision on damaged pallet",
           "You'll have a decision from the claims team in two days.", now + timedelta(days=1), "open",
           "support", "high", created_days_ago=1, due_text="in two days")

    # History so the dashboard trend and reliability scores have shape.
    for w in range(1, 8):
        for j, (m, client) in enumerate([(M_ADA, "Bello Foods"), (M_TUNDE, "Coastal Pharma"), (M_KEMI, "Harmattan Retail")]):
            created = 7 * w + j
            for n in range(1 + (w + j) % 3):
                due = now - timedelta(days=created - 3)
                hit = (w + j + n) % 5 != 0
                commit(m, None, None, client, f"Follow-up #{w}{j}{n}", "Historical commitment.", due,
                       "fulfilled" if hit else "missed", ["follow_up", "deliverable", "information"][n % 3],
                       completed=due - timedelta(hours=6) if hit else None, created_days_ago=created)

    t["calls"] = calls
    t["transcript_segments"] = [{"id": i + 1, **s} for i, s in enumerate(segs)]
    store._seq = len(segs)
    t["commitments"] = []
    t["commitment_events"] = []
    import uuid as _uuid

    for c in commits:
        c["id"] = str(_uuid.uuid4())
        c["updated_at"] = c["created_at"]
        t["commitments"].append(c)
