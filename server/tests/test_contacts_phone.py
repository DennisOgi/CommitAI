from fastapi.testclient import TestClient

from commitai.api import app
from commitai.seed import ADA, CHIDI, KEMI


def H(uid):
    return {"Authorization": f"Bearer dev:{uid}"}


def test_reimport_never_duplicates_and_phone_matching_both_ways():
    with TestClient(app) as c:
        c.post("/v1/presence", headers=H(KEMI), json={"mode": "personal"})
        # Ada registers her number (local format is fine).
        r = c.patch("/v1/me/settings", headers=H(ADA), json={"phone": "0803 555 0101"})
        assert r.status_code == 200 and r.json()["phone_e164"] == "+2348035550101"
        # Nobody else can claim it.
        assert c.patch("/v1/me/settings", headers=H(CHIDI), json={"phone": "+2348035550101"}).status_code == 409
        assert c.patch("/v1/me/settings", headers=H(CHIDI), json={"phone": "12"}).status_code == 422

        book = [{"name": "Ada", "phones": ["08035550101"]},
                {"name": "Chidi", "phones": ["+234 803 555 0202"]},
                {"name": "Plumber", "phones": ["0803 555 0303"]}]
        first = c.post("/v1/contacts/import", headers=H(KEMI), json={"contacts": book}).json()
        assert first["imported"] == 3 and first["on_app"] == 1          # Ada matched by number
        again = c.post("/v1/contacts/import", headers=H(KEMI), json={"contacts": book}).json()
        assert again["imported"] == 0 and again["skipped"] == 3          # re-sync adds nothing
        mine = c.get("/v1/contacts", headers=H(KEMI)).json()
        assert len([x for x in mine if x.get("source") == "phone"]) == 3
        assert next(x for x in mine if x["name"] == "Ada")["app_user_id"] == ADA

        # Chidi joins later and adds his number: Kemi's existing contact lights up immediately.
        c.patch("/v1/me/settings", headers=H(CHIDI), json={"phone": "08035550202"})
        chidi = next(x for x in c.get("/v1/contacts", headers=H(KEMI)).json() if x["name"] == "Chidi")
        assert chidi["app_user_id"] == CHIDI

        # Search by number finds the account.
        hits = c.get("/v1/users/search", headers=H(KEMI), params={"q": "0803 555 0202"}).json()
        assert [h["user_id"] for h in hits] == [CHIDI]

        # Changing number unlinks the old one.
        c.patch("/v1/me/settings", headers=H(CHIDI), json={"phone": "08035550909"})
        chidi = next(x for x in c.get("/v1/contacts", headers=H(KEMI)).json() if x["name"] == "Chidi")
        assert chidi["app_user_id"] is None
