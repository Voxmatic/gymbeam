#!/usr/bin/env python3
"""GymOS Phase 1 acceptance tests. Real PostgreSQL 16, fresh database every run.

Auth is simulated Supabase-style: request.jwt.claims GUC + SET ROLE authenticated|service_role.
Concurrency tests use real parallel connections (threads), never sequential calls.
"""
import datetime as dt
import json
import os
import pathlib
import sys
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg.types.json import Jsonb

ROOT = pathlib.Path(__file__).resolve().parent.parent
PGHOST = os.environ.get("GYMOS_PGHOST", "127.0.0.1")
PGPORT = int(os.environ.get("GYMOS_PGPORT", "55432"))
PGUSER = os.environ.get("GYMOS_PGUSER", "postgres")
TODAY = dt.date.today()

FAILURES = []
PASSES = []


def connect(dbname, role=None, claims=None):
    c = psycopg.connect(host=PGHOST, port=PGPORT, user=PGUSER, dbname=dbname, autocommit=True)
    if claims is not None:
        c.execute("select set_config('request.jwt.claims', %s, false)", (json.dumps(claims),))
    if role:
        c.execute("set role " + role)
    return c


def as_user(dbname, uid):
    return connect(dbname, "authenticated", {"sub": str(uid), "role": "authenticated"})


def as_service(dbname):
    return connect(dbname, "service_role", {"role": "service_role"})


def as_super(dbname, super_id):
    return as_user(dbname, super_id)


def rpc(conn, fn, *args):
    args = [Jsonb(a) if isinstance(a, (dict, list)) else a for a in args]
    ph = ", ".join(["%s"] * len(args))
    cur = conn.execute(f"select app.{fn}({ph})", args)
    row = cur.fetchone()
    return row[0] if row else None


def rows(conn, sql, args=()):
    return conn.execute(sql, args).fetchall()


def scalar(conn, sql, args=()):
    r = conn.execute(sql, args).fetchone()
    return r[0] if r else None


def expect_error(label, fn_call, token):
    try:
        fn_call()
    except psycopg.Error as e:
        if token in str(e):
            return str(e).splitlines()[0]
        raise AssertionError(f"{label}: expected error containing {token!r}, got: {e}") from e
    raise AssertionError(f"{label}: expected error {token!r}, but call succeeded")


def check(name, cond, detail=""):
    if cond:
        PASSES.append(name)
        print(f"  PASS {name}")
    else:
        FAILURES.append(name)
        print(f"  FAIL {name} {detail}")


def give_membership(pg, gym, member, plan, ends_offset, starts_offset=-30):
    return scalar(pg, """
        insert into public.memberships (gym_id, member_id, plan_id, starts_on, ends_on)
        values (%s,%s,%s,%s,%s) returning id""",
        (gym, member, plan, TODAY + dt.timedelta(days=starts_offset), TODAY + dt.timedelta(days=ends_offset)))


def make_member(pg, gym, phone, name="Member", branch=None):
    return scalar(pg, """
        insert into public.users (gym_id, branch_id, role, full_name, phone)
        values (%s,%s,'member',%s,%s) returning id""", (gym, branch, name, phone))


def setup_fresh_db():
    admin = connect("postgres")
    dbname = "gymos_test_" + uuid.uuid4().hex[:10]
    admin.execute(f"drop database if exists {dbname}")
    admin.execute(f"create database {dbname}")
    admin.close()
    c = connect(dbname)
    for f in sorted((ROOT / "supabase" / "migrations").glob("*.sql")):
        c.execute(f.read_text(encoding="utf-8"))
    c.close()
    return dbname


def build_fixture(dbname):
    pg = connect(dbname)
    fx = {}
    fx["super"] = scalar(pg, """
        insert into public.users (role, full_name, phone) values ('super_admin','Platform Admin','+919000000001')
        returning id""")
    su = as_super(dbname, fx["super"])
    a = rpc(su, "onboard_gym", "Alpha Fitness", "alpha", "Asha Owner", "+919000000010", 5000, "en")
    b = rpc(su, "onboard_gym", "Beta Gym", "beta", "Bala Owner", "+919000000020", 7000, "en")
    su.close()
    fx["gym_a"], fx["branch_a"], fx["owner_a"] = a["gym_id"], a["branch_id"], a["owner_id"]
    fx["gym_b"], fx["branch_b"], fx["owner_b"] = b["gym_id"], b["branch_id"], b["owner_id"]
    pg.execute("update public.gyms set gst_enabled = true, gstin = '27ABCDE1234F1Z5' where id = %s", (fx["gym_a"],))
    fx["branch_a2"] = scalar(pg, "insert into public.branches (gym_id, name, code) values (%s,'Second','SEC') returning id", (fx["gym_a"],))
    fx["manager_a"] = scalar(pg, "insert into public.users (gym_id, role, full_name, phone) values (%s,'manager','Manu Manager','+919000000011') returning id", (fx["gym_a"],))
    fx["bm_a2"] = scalar(pg, "insert into public.users (gym_id, branch_id, role, full_name, phone) values (%s,%s,'manager','Bina Branch','+919000000012') returning id", (fx["gym_a"], fx["branch_a2"]))
    fx["recep_a"] = scalar(pg, "insert into public.users (gym_id, role, full_name, phone) values (%s,'receptionist','Ritu Desk','+919000000013') returning id", (fx["gym_a"],))
    fx["trainer_a"] = scalar(pg, "insert into public.users (gym_id, role, full_name, phone) values (%s,'trainer','Tara Trainer','+919000000014') returning id", (fx["gym_a"],))
    fx["plan_m"] = scalar(pg, """insert into public.membership_plans (gym_id, code, name, kind, duration_days, price_paise)
        values (%s,'monthly','Monthly','membership',30,150000) returning id""", (fx["gym_a"],))
    fx["plan_ai"] = scalar(pg, """insert into public.membership_plans (gym_id, code, name, kind, duration_days, price_paise)
        values (%s,'ai30','AI Trainer 30d','ai_addon',30,49900) returning id""", (fx["gym_a"],))
    fx["plan_b"] = scalar(pg, """insert into public.membership_plans (gym_id, code, name, kind, duration_days, price_paise)
        values (%s,'monthly','Monthly','membership',30,120000) returning id""", (fx["gym_b"],))
    fx["members_a"] = [make_member(pg, fx["gym_a"], f"+91980000{i:04d}", f"A Member {i}") for i in range(16)]
    fx["members_b"] = [make_member(pg, fx["gym_b"], f"+91981000{i:04d}", f"B Member {i}") for i in range(3)]
    pg.close()
    return fx


def test_cross_gym_fk(db, fx):
    svc = as_service(db)
    expect_error("cross-gym membership FK",
        lambda: svc.execute("""insert into public.memberships (gym_id, member_id, plan_id, starts_on, ends_on)
            values (%s,%s,%s,%s,%s)""",
            (fx["gym_a"], fx["members_b"][0], fx["plan_m"], TODAY, TODAY + dt.timedelta(days=30))),
        "foreign key")
    expect_error("cross-gym payment FK",
        lambda: rpc(svc, "record_payment", fx["gym_a"], fx["owner_a"], fx["members_b"][0],
                    "membership", 1000, "cash", None, None, None),
        "MEMBER_NOT_IN_GYM")
    svc.close()


def test_member_rls(db, fx):
    m1, m2 = fx["members_a"][0], fx["members_a"][1]
    pg = connect(db)
    give_membership(pg, fx["gym_a"], m1, fx["plan_m"], 10)
    give_membership(pg, fx["gym_a"], m2, fx["plan_m"], 10)
    pg.close()
    staff = as_user(db, fx["recep_a"])
    rpc(staff, "record_payment", fx["gym_a"], fx["recep_a"], m1, "membership", 150000, "cash", None, None, None)
    rpc(staff, "record_payment", fx["gym_a"], fx["recep_a"], m2, "membership", 150000, "cash", None, None, None)
    staff.close()
    c1 = as_user(db, m1)
    pays = rows(c1, "select member_id from public.payments")
    check("member sees only own payments", len(pays) == 1 and pays[0][0] == m1, str(pays))
    users = rows(c1, "select id from public.users")
    check("member cannot list users (self only)", len(users) == 1 and users[0][0] == m1, str(len(users)))
    expect_error("member direct payment INSERT denied",
        lambda: c1.execute("""insert into public.payments
            (gym_id, member_id, purpose, amount_paise, taxable_paise, gst_paise, method, invoice_no)
            values (%s,%s,'membership',100,100,0,'cash','INV-HACK-1')""", (fx["gym_a"], m1)),
        "permission denied")
    other = rows(c1, "select id from public.memberships where member_id <> %s", (m1,))
    check("member cannot read other memberships", len(other) == 0)
    c1.close()


def test_branch_isolation(db, fx):
    pg = connect(db)
    ma2 = make_member(pg, fx["gym_a"], "+919820000001", "A2 Member", fx["branch_a2"])
    ma1 = make_member(pg, fx["gym_a"], "+919820000002", "A1 Member", fx["branch_a"])
    cls2 = scalar(pg, "insert into public.classes (gym_id, branch_id, name, capacity) values (%s,%s,'Yoga A2',10) returning id", (fx["gym_a"], fx["branch_a2"]))
    cls1 = scalar(pg, "insert into public.classes (gym_id, branch_id, name, capacity) values (%s,%s,'Yoga A1',10) returning id", (fx["gym_a"], fx["branch_a"]))
    pg.close()
    bm = as_user(db, fx["bm_a2"])
    users = {r[0] for r in rows(bm, "select id from public.users where role = 'member'")}
    check("branch manager sees only own-branch members", ma2 in users and ma1 not in users, str(users))
    classes = {r[0] for r in rows(bm, "select id from public.classes")}
    check("branch manager blind to other branch classes", cls2 in classes and cls1 not in classes)
    bm.close()
    owner = as_user(db, fx["owner_a"])
    all_users = {r[0] for r in rows(owner, "select id from public.users where role = 'member'")}
    check("gym-wide owner sees both branches", ma1 in all_users and ma2 in all_users)
    owner.close()


def test_vault(db, fx):
    svc = as_service(db)
    su = as_super(db, fx["super"])
    secret = b"super-secret-key-material"
    nonce = b"0123456789ab"
    rpc(su, "set_provider_key", None, "interakt", secret, nonce, "fp_abc123", 1)
    rpc(su, "set_provider_key", fx["gym_a"], "interakt", b"gym-key", nonce, "fp_gym999", 1)
    owner = as_user(db, fx["owner_a"])
    check("owner cannot read provider_keys", rows(owner, "select * from public.provider_keys") == [])
    expect_error("owner cannot set keys", lambda: rpc(owner, "set_provider_key", fx["gym_a"], "interakt", b"x", nonce, "fp", 1), "SUPER_ONLY")
    expect_error("owner cannot list keys", lambda: rpc(owner, "list_provider_keys", fx["gym_a"]), "SUPER_ONLY")
    expect_error("owner cannot call get_provider_key (revoked)",
        lambda: rpc(owner, "get_provider_key", fx["gym_a"], "interakt"), "permission denied")
    owner.close()
    meta = rows(su, "select * from app.list_provider_keys(%s)", (fx["gym_a"],))
    check("super keys list returns metadata only", len(meta) >= 1 and all(len(r) == 5 for r in meta), str(meta))
    su.close()
    got = rows(svc, "select * from app.get_provider_key(%s,'interakt')", (fx["gym_a"],))
    check("service fetches gym ciphertext", got and bytes(got[0][0]) == b"gym-key", str(got))
    got_pf = rows(svc, "select * from app.get_provider_key(%s,'interakt')", (fx["gym_b"],))
    check("platform fallback for gym without key", got_pf and bytes(got_pf[0][0]) == secret)
    svc.close()


def test_payment_replay_and_gst(db, fx):
    m = fx["members_a"][2]
    svc = as_service(db)
    p1 = rpc(svc, "record_payment", fx["gym_a"], m, m, "membership", 11800, "razorpay", "pay_replay_1", "order_r1", None)
    p2 = rpc(svc, "record_payment", fx["gym_a"], m, m, "membership", 11800, "razorpay", "pay_replay_1", "order_r1", None)
    n = scalar(svc, "select count(*) from public.payments where provider_payment_id = 'pay_replay_1'")
    check("payment replay returns same id, 1 row", p1 == p2 and n == 1, f"{p1} {p2} {n}")
    gst, taxable = rows(svc, "select gst_paise, taxable_paise from public.payments where id = %s", (p1,))[0]
    check("GST-inclusive 11800 -> 1800 gst / 10000 taxable", gst == 1800 and taxable == 10000, f"{gst}/{taxable}")
    staff = as_user(db, fx["recep_a"])
    expect_error("razorpay method refused for staff",
        lambda: rpc(staff, "record_payment", fx["gym_a"], fx["recep_a"], m, "membership", 100, "razorpay", "pay_x", None, None),
        "SERVICE_ONLY")
    staff.close()
    svc.close()


def test_renewal_chain(db, fx):
    m = fx["members_a"][3]
    pg = connect(db)
    give_membership(pg, fx["gym_a"], m, fx["plan_m"], 5)
    pg.close()
    staff = as_user(db, fx["manager_a"])
    rpc(staff, "renew_membership", fx["gym_a"], fx["manager_a"], m, fx["plan_m"], None, None)
    rpc(staff, "renew_membership", fx["gym_a"], fx["manager_a"], m, fx["plan_m"], None, None)
    starts = rows(staff, "select starts_on, ends_on from public.memberships where member_id = %s order by starts_on", (m,))
    ok = (starts[1][0] == starts[0][1] + dt.timedelta(days=1)
          and starts[2][0] == starts[1][1] + dt.timedelta(days=1)
          and (starts[1][1] - starts[1][0]).days == 29)
    check("renewals chain +1 day, 30-day span", ok, str(starts))
    staff.close()


def test_actor_mismatch(db, fx):
    m1, m2 = fx["members_a"][0], fx["members_a"][1]
    c = as_user(db, m1)
    expect_error("ACTOR_MISMATCH on spoofed actor",
        lambda: rpc(c, "save_workout", m2, dt.datetime.now(dt.timezone.utc), None, "{}", "manual"),
        "ACTOR_MISMATCH")
    anon = connect(db, "authenticated", {"role": "authenticated"})
    check("no-sub claims see nothing (NULL-safe)", rows(anon, "select id from public.users") == [])
    anon.close()
    c.close()


def test_online_payment_flow(db, fx):
    m = fx["members_a"][4]
    svc = as_service(db)
    pg = connect(db)
    pg.execute("update public.gyms set razorpay_linked_account_id = 'acc linked123' where id = %s", (fx["gym_a"],))
    pg.close()
    intent = rpc(svc, "create_payment_intent", fx["gym_a"], m, m, "membership", fx["plan_m"], None)
    check("intent server-priced from plan", intent["amount_paise"] == 150000, str(intent))
    again = rpc(svc, "create_payment_intent", fx["gym_a"], m, m, "membership", fx["plan_m"], None)
    check("intent reused <15min", again["reused"] is True and again["intent_id"] == intent["intent_id"])
    check("receipt <=40 ASCII", len(intent["receipt"]) <= 40 and intent["receipt"].isascii())
    rpc(svc, "attach_order", intent["intent_id"], "order_test_1")
    payload = {"payload": {"payment": {"entity": {
        "id": "pay_test_1", "order_id": "order_test_1", "amount": 150000, "currency": "INR", "status": "captured"}}}}
    tampered = json.loads(json.dumps(payload))
    tampered["payload"]["payment"]["entity"]["amount"] = 999
    expect_error("tampered amount AMOUNT_MISMATCH", lambda: rpc(svc, "apply_razorpay_payment", tampered), "AMOUNT_MISMATCH")
    res = rpc(svc, "apply_razorpay_payment", payload)
    check("captured webhook fulfils membership", res.get("fulfilled") == "membership", str(res))
    replay = rpc(svc, "apply_razorpay_payment", payload)
    check("webhook replay already_paid", replay.get("already_paid") is True, str(replay))
    n = scalar(svc, "select count(*) from public.payments where provider_payment_id = 'pay_test_1'")
    check("replay did not double-charge", n == 1)
    tr = rows(svc, "select status, amount_paise from public.route_transfers where payment_id = %s", (res["payment_id"],))
    check("route transfer queued", tr and tr[0][0] == "pending" and tr[0][1] == 150000, str(tr))
    unknown = rpc(svc, "apply_razorpay_payment", {"payload": {"payment": {"entity": {
        "id": "pay_unknown", "order_id": "order_unknown", "amount": 100, "currency": "INR", "status": "captured"}}}})
    aud = scalar(svc, "select count(*) from public.audit_log where action = 'webhook.unknown_order'")
    check("unknown order ignored + audited", unknown.get("ignored") == "unknown_order" and aud == 1, str(unknown))
    notcap = rpc(svc, "apply_razorpay_payment", {"payload": {"payment": {"entity": {
        "id": "pay_nc", "order_id": "order_test_1", "amount": 150000, "currency": "INR", "status": "authorized"}}}})
    check("non-captured ignored", notcap.get("ignored") == "not_captured")
    svc.close()


def test_webhook_dedupe_and_rate_limit(db, fx):
    svc = as_service(db)
    t = rpc(svc, "register_webhook_event", "razorpay", "evt_1", "payment.captured", "{}")
    f = rpc(svc, "register_webhook_event", "razorpay", "evt_1", "payment.captured", "{}")
    check("webhook dedupe true then false", t is True and f is False, f"{t}/{f}")
    results = [rpc(svc, "check_rate_limit", "checkout:test", 3, 60) for _ in range(4)]
    check("rate limit t,t,t,f", results == [True, True, True, False], str(results))
    svc.close()


def test_saas_billing(db, fx):
    pg = connect(db)
    period = TODAY.replace(day=1)
    eom = (period + dt.timedelta(days=32)).replace(day=1) - dt.timedelta(days=1)
    for i in (5, 6):
        pg.execute("insert into public.memberships (gym_id, member_id, plan_id, starts_on, ends_on) values (%s,%s,%s,%s,%s)",
                   (fx["gym_a"], fx["members_a"][i], fx["plan_m"], period, eom))
    pg.execute("insert into public.memberships (gym_id, member_id, plan_id, starts_on, ends_on) values (%s,%s,%s,%s,%s)",
               (fx["gym_a"], fx["members_a"][6], fx["plan_m"], period, eom))
    pg.close()
    svc = as_service(db)
    r1 = rpc(svc, "run_saas_billing", period)
    r2 = rpc(svc, "run_saas_billing", period)
    inv = rows(svc, "select member_count, amount_paise from public.saas_invoices where gym_id = %s and period = %s", (fx["gym_a"], period))
    expected = scalar(svc, """select count(distinct m.member_id) from public.memberships m
        where m.gym_id = %s and m.status = 'active' and m.starts_on <= %s and m.ends_on >= %s""",
        (fx["gym_a"], eom, eom))
    check("billing idempotent per (gym, period)", r1["created"] >= 1 and r2["created"] == 0 and r2["skipped"] >= 1, f"{r1} {r2}")
    check("invoice = distinct members x price", inv and inv[0][0] == expected and inv[0][1] == expected * 5000, f"{inv} expected={expected}")
    svc.close()


def test_booking_race(db, fx):
    pg = connect(db)
    cls = scalar(pg, "insert into public.classes (gym_id, branch_id, name, capacity, waitlist_capacity) values (%s,%s,'Race Class',3,2) returning id", (fx["gym_a"], fx["branch_a"]))
    sess = scalar(pg, """insert into public.class_sessions (gym_id, class_id, starts_at, ends_at, capacity, waitlist_capacity)
        values (%s,%s,%s,%s,3,2) returning id""",
        (fx["gym_a"], cls, dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=2),
         dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=2, hours=1)))
    racers = fx["members_a"][:12]
    for m in racers:
        give_membership(pg, fx["gym_a"], m, fx["plan_m"], 10)
    pg.close()

    def book(m):
        c = as_user(db, m)
        try:
            return ("ok", rpc(c, "book_class", sess, None))
        except psycopg.Error as e:
            return ("err", str(e).splitlines()[0])
        finally:
            c.close()

    with ThreadPoolExecutor(max_workers=12) as ex:
        results = list(ex.map(book, racers))
    confirmed = sum(1 for k, v in results if k == "ok" and v["status"] == "confirmed")
    waitlisted = sum(1 for k, v in results if k == "ok" and v["status"] == "waitlisted")
    full = sum(1 for k, v in results if k == "err" and "SESSION_FULL" in v)
    check("12-way race: 3 confirmed / 2 waitlisted / 7 SESSION_FULL",
          confirmed == 3 and waitlisted == 2 and full == 7,
          f"confirmed={confirmed} waitlisted={waitlisted} full={full}")
    pg = connect(db)
    db_counts = rows(pg, "select status, count(*) from public.bookings where session_id = %s group by status", (sess,))
    pg.close()
    check("race DB state matches", dict(db_counts) == {"confirmed": 3, "waitlisted": 2}, str(db_counts))
    return sess


def test_cancel_promotes_and_rebook(db, fx, sess):
    pg = connect(db)
    conf = rows(pg, "select id, member_id, created_at from public.bookings where session_id = %s and status = 'confirmed' order by created_at, id", (sess,))
    wait = rows(pg, "select id, member_id from public.bookings where session_id = %s and status = 'waitlisted' order by created_at, id", (sess,))
    pg.close()
    oldest_wait_id, oldest_wait_member = wait[0]
    cancelling_member = conf[0][1]
    c = as_user(db, cancelling_member)
    res = rpc(c, "cancel_booking", conf[0][0], None)
    check("cancel promotes oldest waitlisted", str(res["promoted"]) == str(oldest_wait_id), str(res))
    svc = as_service(db)
    push = rows(svc, "select id from public.notification_outbox where dedupe_key = %s", (f"promoted:{oldest_wait_id}",))
    check("promotion enqueues push", len(push) == 1)
    svc.close()
    rebook = rpc(c, "book_class", sess, None)
    check("cancelled member can rebook (waitlisted)", rebook["status"] == "waitlisted", str(rebook))
    c.close()
    staff = as_user(db, fx["manager_a"])
    res2 = rpc(staff, "cancel_booking", conf[1][0], None)
    check("second promotion picks next oldest", str(res2["promoted"]) == str(wait[1][0]), str(res2))
    staff.close()


def test_wallet(db, fx):
    svc = as_service(db)
    m7, m8 = fx["members_a"][7], fx["members_a"][8]
    rpc(svc, "wallet_purchase", fx["gym_a"], 5, m7, None)
    for i in range(4):
        rpc(svc, "enqueue_notification", fx["gym_a"], m7, "whatsapp", "membership_expiring", "en", "{}", f"wa4:{i}")
    claimed = rows(svc, "select out_id, out_wallet_reservation, out_reservation_id from app.claim_outbox(20)")
    free = sum(1 for r in claimed if r[1] == "free")
    credit = sum(1 for r in claimed if r[1] == "credit")
    bal = scalar(svc, "select credit_balance from public.whatsapp_wallets where gym_id = %s", (fx["gym_a"],))
    check("4 msgs -> 3 free + 1 credit, balance 4", free == 3 and credit == 1 and bal == 4, f"{free}/{credit}/{bal}")
    credit_row = next(r for r in claimed if r[1] == "credit")
    rpc(svc, "complete_outbox", credit_row[0], True, False, None, "msg_ok_1")
    st = scalar(svc, "select status from public.notification_outbox where id = %s", (credit_row[0],))
    cap = scalar(svc, "select count(*) from public.whatsapp_ledger where reservation_id = %s and kind = 'capture'", (credit_row[2],))
    check("ok -> sent + capture", st == "sent" and cap == 1, f"{st}/{cap}")
    tr_row = claimed[1]
    rpc(svc, "complete_outbox", tr_row[0], False, False, "429 rate limited", None)
    st2, nxt = rows(svc, "select status, next_attempt_at from public.notification_outbox where id = %s", (tr_row[0],))[0]
    check("transient -> pending + backoff", st2 == "pending" and nxt > dt.datetime.now(dt.timezone.utc), f"{st2}/{nxt}")
    perm_row = claimed[2]
    rpc(svc, "complete_outbox", perm_row[0], False, True, "400 bad template", None)
    st3 = scalar(svc, "select status from public.notification_outbox where id = %s", (perm_row[0],))
    rel = scalar(svc, "select count(*) from public.whatsapp_ledger where reservation_id = %s and kind in ('release','free_release')", (perm_row[2],))
    check("permanent -> dead + release", st3 == "dead" and rel == 1, f"{st3}/{rel}")
    pg = connect(db)
    pg.execute("update public.notification_outbox set locked_at = now() - interval '10 minutes' where id = %s", (claimed[3][0],))
    pg.close()
    swept = rpc(svc, "sweep_outbox")
    st4 = scalar(svc, "select status from public.notification_outbox where id = %s", (claimed[3][0],))
    check("sweep recovers stuck sending row", swept >= 1 and st4 == "pending", f"{swept}/{st4}")
    rpc(svc, "complete_outbox", claimed[3][0], True, False, None, "msg_swept_1")
    rpc(svc, "wallet_purchase", fx["gym_a"], 1, m8, None)
    for i in range(10):
        rpc(svc, "enqueue_notification", fx["gym_a"], m8, "whatsapp", "membership_overdue", "en", "{}", f"wa10:{i}")

    def claim_one(_):
        c = as_service(db)
        try:
            return rows(c, "select out_id, out_channel, out_wallet_reservation from app.claim_outbox(1)")
        finally:
            c.close()

    with ThreadPoolExecutor(max_workers=10) as ex:
        batches = list(ex.map(claim_one, range(10)))
    flat = [r for b in batches for r in b]
    wa_free = sum(1 for r in flat if r[1] == "whatsapp" and r[2] == "free")
    wa_credit = sum(1 for r in flat if r[1] == "whatsapp" and r[2] == "credit")
    dead = scalar(svc, "select count(*) from public.notification_outbox where dedupe_key like 'wa10:%%' and status = 'dead' and last_error = 'INSUFFICIENT_CREDITS'")
    fallbacks = scalar(svc, "select count(*) from public.notification_outbox where dedupe_key like 'fallback:wa10:%%' and channel = 'push'")
    bal0 = scalar(svc, "select credit_balance from public.whatsapp_wallets where gym_id = %s", (fx["gym_a"],))
    check("10 concurrent claimers: 3 free + 5 credit + 2 dead w/ push fallbacks, balance 0",
          wa_free == 3 and wa_credit == 5 and dead == 2 and fallbacks == 2 and bal0 == 0,
          f"free={wa_free} credit={wa_credit} dead={dead} fb={fallbacks} bal={bal0}")
    svc.close()


def test_consent_gate(db, fx):
    su = as_super(db, fx["super"])
    rpc(su, "set_feature_flag", fx["gym_b"], "require_consent", True)
    su.close()
    pg = connect(db)
    cls = scalar(pg, "insert into public.classes (gym_id, branch_id, name, capacity) values (%s,%s,'B Class',5) returning id", (fx["gym_b"], fx["branch_b"]))
    sess = scalar(pg, """insert into public.class_sessions (gym_id, class_id, starts_at, ends_at, capacity)
        values (%s,%s,%s,%s,5) returning id""",
        (fx["gym_b"], cls, dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
         dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1, hours=1)))
    give_membership(pg, fx["gym_b"], fx["members_b"][0], fx["plan_b"], 10)
    pg.close()
    c = as_user(db, fx["members_b"][0])
    expect_error("consent gate blocks booking", lambda: rpc(c, "book_class", sess, None), "CONSENT_REQUIRED")
    rpc(c, "accept_consent", fx["members_b"][0], "data", "v1")
    rpc(c, "accept_consent", fx["members_b"][0], "data", "v1")
    n = scalar(c, "select count(*) from public.consents where member_id = %s and kind = 'data'", (fx["members_b"][0],))
    check("accept_consent idempotent", n == 1)
    res = rpc(c, "book_class", sess, None)
    check("booking allowed after consent", res["status"] == "confirmed", str(res))
    c.close()
    return sess


def test_reminders(db, fx):
    pg = connect(db)
    m9, m11 = fx["members_a"][9], fx["members_a"][11]
    m10 = make_member(pg, fx["gym_a"], "+919800008888", "Overdue Person")
    give_membership(pg, fx["gym_a"], m9, fx["plan_m"], 3)
    give_membership(pg, fx["gym_a"], m10, fx["plan_m"], -1)
    give_membership(pg, fx["gym_a"], m11, fx["plan_m"], 3)
    pg.close()
    svc = as_service(db)
    r1 = rpc(svc, "generate_payment_reminders", 3)
    chan = scalar(svc, "select channel from public.notification_outbox where dedupe_key = %s", (f"expiry:{m9}:{TODAY + dt.timedelta(days=3)}",))
    check("pilot default: reminders go to push", chan == "push", str(chan))
    check("expiring + overdue reminders created", r1["expiring_new"] >= 2 and r1["overdue_new"] >= 1, str(r1))
    r2 = rpc(svc, "generate_payment_reminders", 3)
    check("reminders deduped on second run", r2["expiring_new"] == 0 and r2["overdue_new"] == 0, str(r2))
    su = as_super(db, fx["super"])
    rpc(su, "set_feature_flag", fx["gym_a"], "whatsapp_enabled", True)
    su.close()
    pg = connect(db)
    m16 = make_member(pg, fx["gym_a"], "+919800009999", "Late Joiner")
    give_membership(pg, fx["gym_a"], m16, fx["plan_m"], 3)
    pg.close()
    r3 = rpc(svc, "generate_payment_reminders", 3)
    chan2 = scalar(svc, "select channel from public.notification_outbox where dedupe_key = %s", (f"expiry:{m16}:{TODAY + dt.timedelta(days=3)}",))
    check("flag switches reminders to whatsapp", r3["expiring_new"] == 1 and chan2 == "whatsapp", f"{r3}/{chan2}")
    svc.close()


def test_import(db, fx):
    staff = as_user(db, fx["manager_a"])
    existing_phone = scalar(staff, "select phone from public.users where id = %s", (fx["members_a"][0],))
    rows_in = [
        {"full_name": "Imported One", "phone": "+919830000001", "plan_code": "monthly", "days_left": 10},
        {"full_name": "Existing Person", "phone": existing_phone},
        {"full_name": "Imported One Again", "phone": "+919830000001"},
        {"full_name": "Bad Phone", "phone": "12345"},
    ]
    res = rpc(staff, "import_members", fx["gym_a"], fx["manager_a"], rows_in)
    check("import 1 inserted / 2 duplicates / 1 invalid",
          res["inserted"] == 1 and res["duplicates"] == 2 and res["invalid"] == 1, str(res))
    new_id = scalar(staff, "select id from public.users where gym_id = %s and phone = '+919830000001'", (fx["gym_a"],))
    ends = scalar(staff, "select ends_on from public.memberships where member_id = %s", (new_id,))
    check("migration membership from days_left", ends == TODAY + dt.timedelta(days=9), str(ends))
    expect_error("import >5000 rows rejected",
        lambda: rpc(staff, "import_members", fx["gym_a"], fx["manager_a"],
                    [{"full_name": "x", "phone": "+919830000002"}] * 5001),
        "TOO_MANY_ROWS")
    staff.close()


def test_dues_and_mark_booking(db, fx, race_sess):
    pg = connect(db)
    m12, m13, m14, m15 = fx["members_a"][12:16]
    give_membership(pg, fx["gym_a"], m12, fx["plan_m"], -1)
    give_membership(pg, fx["gym_a"], m13, fx["plan_m"], 0)
    give_membership(pg, fx["gym_a"], m14, fx["plan_m"], 7)
    give_membership(pg, fx["gym_a"], m15, fx["plan_m"], 8)
    pg.close()
    staff = as_user(db, fx["owner_a"])
    buckets = {r[0]: r[1] for r in rows(staff, "select member_id, bucket from public.dues where member_id = any(%s)", ([m12, m13, m14, m15],))}
    check("dues buckets -1/0/7/8", buckets == {m12: "overdue", m13: "expiring", m14: "expiring", m15: "active"}, str(buckets))
    staff.close()
    c = as_user(db, m12)
    own = rows(c, "select member_id from public.dues")
    check("member sees own dues only", len(own) == 1 and own[0][0] == m12, str(own))
    pg = connect(db)
    conf = scalar(pg, "select id from public.bookings where session_id = %s and status = 'confirmed' limit 1", (race_sess,))
    pg.close()
    expect_error("member cannot mark_booking", lambda: rpc(c, "mark_booking", conf, m12, "attended"), "FORBIDDEN")
    c.close()
    trainer = as_user(db, fx["trainer_a"])
    rpc(trainer, "mark_booking", conf, fx["trainer_a"], "attended")
    aud = scalar(trainer, "select count(*) from public.audit_log where action = 'booking.marked' and entity_id = %s", (conf,))
    check("staff marks attended + audit", aud == 1)
    trainer.close()


def main():
    import traceback
    db = setup_fresh_db()
    print(f"fresh database: {db} (PG16, all migrations re-applied)")
    fx = build_fixture(db)

    def run(name, fn, *args):
        print(f"[{name}]")
        try:
            return fn(db, fx, *args)
        except Exception as e:
            FAILURES.append(name)
            print(f"  ERROR {name}: {e}")
            traceback.print_exc()
            return None

    run("cross_gym_fk", test_cross_gym_fk)
    run("member_rls", test_member_rls)
    run("branch_isolation", test_branch_isolation)
    run("vault", test_vault)
    run("payment_replay_and_gst", test_payment_replay_and_gst)
    run("renewal_chain", test_renewal_chain)
    run("actor_mismatch", test_actor_mismatch)
    run("online_payment_flow", test_online_payment_flow)
    run("webhook_dedupe_and_rate_limit", test_webhook_dedupe_and_rate_limit)
    run("saas_billing", test_saas_billing)
    sess = run("booking_race", test_booking_race)
    if sess:
        run("cancel_promotes_and_rebook", test_cancel_promotes_and_rebook, sess)
    run("wallet", test_wallet)
    run("consent_gate", test_consent_gate)
    run("reminders", test_reminders)
    run("import", test_import)
    if sess:
        run("dues_and_mark_booking", test_dues_and_mark_booking, sess)

    print(f"\n{len(PASSES)} passed, {len(FAILURES)} failed")
    if FAILURES:
        print("FAILED:", ", ".join(FAILURES))
        print(f"database kept for debugging: {db}")
        sys.exit(1)
    admin = connect("postgres")
    admin.execute(f"drop database if exists {db}")
    admin.close()
    print("all green; test database dropped")


if __name__ == "__main__":
    main()