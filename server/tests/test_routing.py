from commitai.routing import Decision, InboundContext, Mode, route_inbound, should_record_outbound


def ctx(**kw):
    base = dict(callee_mode=Mode.personal, callee_org_id=None, call_is_corporate=False)
    return InboundContext(**{**base, **kw})


def test_corporate_user_holds_personal_calls():
    r = route_inbound(ctx(callee_mode=Mode.corporate, callee_org_id="o1"))
    assert r.decision is Decision.blocked_mode and not r.record


def test_corporate_user_receives_corporate_calls_recorded():
    r = route_inbound(ctx(callee_mode=Mode.corporate, callee_org_id="o1", call_is_corporate=True))
    assert r.decision is Decision.ring and r.record


def test_known_client_gets_through_even_from_personal_mode():
    r = route_inbound(ctx(callee_mode=Mode.corporate, callee_org_id="o1", caller_is_org_client=True))
    assert r.decision is Decision.ring and r.record


def test_personal_calls_never_recorded():
    r = route_inbound(ctx())
    assert r.decision is Decision.ring and not r.record
    assert not should_record_outbound(Mode.personal)


def test_off_duty_policy():
    assert route_inbound(ctx(call_is_corporate=True)).decision is Decision.off_duty
    r = route_inbound(ctx(call_is_corporate=True, off_duty_policy="ring"))
    assert r.decision is Decision.ring and r.record
