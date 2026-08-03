# tradefinance.lex — electronic bill of lading + letter of credit (trade-finance
# pack scaffold, #127).
#
# The heaviest vertical, built from two primitives the platform already has:
#
#   eBL   a dual-signed custody chain across carriers IS an electronic bill of
#         lading — a document of TITLE. This registry adds the title layer on
#         top: an eBL names goods + parties + the custody trailer_ref, and title
#         is TRANSFERRED by endorsement. MLETR's "sole control" rule holds — only
#         the current holder may endorse, and each endorsement is a hash-chained
#         event, so the title history replays and re-verifies.
#
#   LC    a letter of credit is "pay the beneficiary when documents prove
#         delivery" — evidence-gated payment, the same gate the construction pack
#         uses. An LC names its required documents and an amount; presenting a
#         document lands a hash on the chain; settlement pays (exact-decimal L1
#         chargeback applicant -> beneficiary) only when EVERY required document
#         is present AND the chain re-verifies. No documents, no euros, and a
#         refusal NAMES what is missing.
#
#   POST /tradefinance/ebl                 — issue {ebl_ref, shipper, consignee, carrier, goods, trailer_ref}
#   POST /tradefinance/ebl/:ref/endorse    — transfer title {to_holder, by}: only the current holder may
#   GET  /tradefinance/ebl/:ref            — parties, current holder, endorsement chain
#   POST /tradefinance/lc                  — open {lc_ref, applicant, beneficiary, issuing_bank, amount_eur, required_documents:[..]}
#   POST /tradefinance/lc/:ref/documents   — present {doc_type, hash, by}
#   POST /tradefinance/lc/:ref/settle      — pay iff every required document proves AND the chain verifies
#   GET  /tradefinance/lc/:ref             — status, presented vs required, amount, paid
#
# Domain pack over the lex-soft core. Zero core changes. This is a v0 SCAFFOLD,
# not the regulated article: no MLETR conformance suite, no bank-rail settlement,
# no possession/transfer legal semantics beyond sole-control endorsement. The
# issue defers the production pack until custody has multi-carrier mileage; this
# proves the two primitives compose.

import "std.str" as str

import "std.list" as list

import "std.int" as int

import "std.float" as float

import "std.time" as time

import "std.sql" as sql

import "lex-schema/json_value" as jv

import "lex-web/router" as router

import "lex-web/ctx" as ctx

import "lex-web/response" as resp

import "lex-trail/log" as tlog

import "lex-soft/src/settlement" as settlement

import "lex-soft/src/evidence" as evidence

import "lex-money/src/money" as money

import "lex-soft/src/positions" as pos

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# The amount as the caller WROTE it — a string passes through, a number renders
# once — so no float rounding creeps into money.
fn jdec(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => str.trim(s),
    Some(JFloat(v)) => float.to_str(v),
    Some(JInt(n)) => int.to_str(n),
    _ => "",
  }
}

fn jlist_str(j :: jv.Json, key :: Str) -> List[Str] {
  match jv.get_field(j, key) {
    Some(JList(xs)) => list.filter(list.map(xs, fn (x :: jv.Json) -> Str {
      match x {
        JStr(s) => str.trim(s),
        _ => "",
      }
    }), fn (s :: Str) -> Bool {
      not str.is_empty(s)
    }),
    _ => [],
  }
}

fn row_str(row :: sql.Row, k :: Str) -> Str {
  match sql.get_str(row, k) {
    Some(v) => v,
    None => "",
  }
}

fn row_int(row :: sql.Row, k :: Str) -> Int {
  match sql.get_int(row, k) {
    Some(v) => v,
    None => 0,
  }
}

# Portable DDL (SQLite + Postgres): TEXT / BIGINT only.
fn ensure_tables(db :: Db) -> [sql] Unit {
  let __e := sql.exec(db, "CREATE TABLE IF NOT EXISTS tf_ebl (ebl_ref TEXT PRIMARY KEY, shipper TEXT NOT NULL, consignee TEXT NOT NULL, carrier TEXT NOT NULL DEFAULT '', goods TEXT NOT NULL DEFAULT '', trailer_ref TEXT NOT NULL DEFAULT '', holder TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'issued', created_ms BIGINT NOT NULL)", [])
  let __l := sql.exec(db, "CREATE TABLE IF NOT EXISTS tf_lc (lc_ref TEXT PRIMARY KEY, applicant TEXT NOT NULL, beneficiary TEXT NOT NULL, issuing_bank TEXT NOT NULL DEFAULT '', amount_dec TEXT NOT NULL DEFAULT '', required_docs TEXT NOT NULL DEFAULT '', status TEXT NOT NULL DEFAULT 'open', paid_dec TEXT NOT NULL DEFAULT '', chargeback TEXT NOT NULL DEFAULT '', created_ms BIGINT NOT NULL)", [])
  ()
}

type Ebl = { shipper :: Str, consignee :: Str, carrier :: Str, goods :: Str, trailer_ref :: Str, holder :: Str, status :: Str }

fn ebl_for(db :: Db, ref :: Str) -> [sql] Option[Ebl] {
  match sql.query(db, "SELECT shipper, consignee, carrier, goods, trailer_ref, holder, status FROM tf_ebl WHERE ebl_ref = ?", [PStr(ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ shipper: row_str(row, "shipper"), consignee: row_str(row, "consignee"), carrier: row_str(row, "carrier"), goods: row_str(row, "goods"), trailer_ref: row_str(row, "trailer_ref"), holder: row_str(row, "holder"), status: row_str(row, "status") }),
    },
  }
}

type Lc = { applicant :: Str, beneficiary :: Str, issuing_bank :: Str, amount_dec :: Str, required_docs :: Str, status :: Str, paid_dec :: Str, chargeback :: Str }

fn lc_for(db :: Db, ref :: Str) -> [sql] Option[Lc] {
  match sql.query(db, "SELECT applicant, beneficiary, issuing_bank, amount_dec, required_docs, status, paid_dec, chargeback FROM tf_lc WHERE lc_ref = ?", [PStr(ref)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some({ applicant: row_str(row, "applicant"), beneficiary: row_str(row, "beneficiary"), issuing_bank: row_str(row, "issuing_bank"), amount_dec: row_str(row, "amount_dec"), required_docs: row_str(row, "required_docs"), status: row_str(row, "status"), paid_dec: row_str(row, "paid_dec"), chargeback: row_str(row, "chargeback") }),
    },
  }
}

# The tip of a ref's event chain (issued/endorsed, or opened/document/settled) —
# the newest event whose payload names this ref. The custody chain_tip precedent.
fn chain_tip(db :: Db, kind_prefix :: Str, field :: Str, ref :: Str) -> [sql] Option[Str] {
  let pat := str.concat("%", str.concat(jv.stringify(JStr(field)), str.concat(":", str.concat(jv.stringify(JStr(ref)), "%"))))
  match sql.query(db, "SELECT id FROM events WHERE kind LIKE ? AND payload_json LIKE ? ORDER BY ts_ms DESC LIMIT 1", [PStr(str.concat(kind_prefix, "%")), PStr(pat)]) {
    Err(_) => None,
    Ok(rows) => match list.head(rows) {
      None => None,
      Some(row) => Some(row_str(row, "id")),
    },
  }
}

# Events for a ref, as JSON — the replayable history the GET endpoints return.
fn events_for(db :: Db, kind_prefix :: Str, field :: Str, ref :: Str) -> [sql] List[jv.Json] {
  let pat := str.concat("%", str.concat(jv.stringify(JStr(field)), str.concat(":", str.concat(jv.stringify(JStr(ref)), "%"))))
  match sql.query(db, "SELECT id, kind, ts_ms FROM events WHERE kind LIKE ? AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(str.concat(kind_prefix, "%")), PStr(pat)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> jv.Json {
      JObj([("event_id", JStr(row_str(row, "id"))), ("kind", JStr(row_str(row, "kind"))), ("ts_ms", JInt(row_int(row, "ts_ms")))])
    }),
  }
}

# Document types presented against an LC (from tradefinance.lc.document events).
fn docs_presented(db :: Db, lc_ref :: Str) -> [sql] List[Str] {
  let pat := str.concat("%\"lc_ref\":", str.concat(jv.stringify(JStr(lc_ref)), "%"))
  match sql.query(db, "SELECT payload_json FROM events WHERE kind='tradefinance.lc.document' AND payload_json LIKE ? ORDER BY ts_ms ASC", [PStr(pat)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, fn (row :: sql.Row) -> Str {
      match jv.parse(row_str(row, "payload_json")) {
        Err(_) => "",
        Ok(p) => jstr(p, "doc_type"),
      }
    }),
  }
}

fn split_docs(s :: Str) -> List[Str] {
  list.filter(str.split(s, ","), fn (d :: Str) -> Bool {
    not str.is_empty(str.trim(d))
  })
}

fn missing_docs(required :: List[Str], have :: List[Str]) -> List[Str] {
  list.filter(required, fn (need :: Str) -> Bool {
    list.is_empty(list.filter(have, fn (h :: Str) -> Bool {
      str.cmp(str.trim(h), str.trim(need)) == 0
    }))
  })
}

# LC settlement route: the chargeback (settlement.record_chargeback_dec)
# already moved money before the following `UPDATE tf_lc SET status = 'settled'
# ...` — if that write fails, the local `status` flag didn't stick (so a retry
# would double-settle), so it must surface as an error, not a silent 201.
fn mount(r :: router.Router, db :: Db) -> [sql] router.Router {
  let __t := ensure_tables(db)
  let with_ebl := router.route_effectful(r, "POST", "/tradefinance/ebl", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "ebl_ref")
        let shipper := jstr(j, "shipper")
        let consignee := jstr(j, "consignee")
        if str.is_empty(ref) or str.is_empty(shipper) or str.is_empty(consignee) {
          resp.bad_request("{\"error\":\"ebl_ref, shipper and consignee are required\"}")
        } else {
          let carrier := jstr(j, "carrier")
          let goods := jstr(j, "goods")
          let trailer := jstr(j, "trailer_ref")
          let stmt := "INSERT INTO tf_ebl (ebl_ref, shipper, consignee, carrier, goods, trailer_ref, holder, status, created_ms) VALUES (?, ?, ?, ?, ?, ?, ?, 'issued', ?) ON CONFLICT (ebl_ref) DO NOTHING"
          match sql.exec(db, stmt, [PStr(ref), PStr(shipper), PStr(consignee), PStr(carrier), PStr(goods), PStr(trailer), PStr(shipper), PInt(time.now_ms())]) {
            Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
            Ok(_) => {
              let log := settlement.trail_on(db)
              let payload := jv.stringify(JObj([("ebl_ref", JStr(ref)), ("shipper", JStr(shipper)), ("consignee", JStr(consignee)), ("carrier", JStr(carrier)), ("goods", JStr(goods)), ("trailer_ref", JStr(trailer)), ("holder", JStr(shipper))]))
              let __x := tlog.append(log, "tradefinance.ebl.issued", None, payload)
              resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("ebl_ref", JStr(ref)), ("holder", JStr(shipper)), ("status", JStr("issued"))])))
            },
          }
        }
      },
    }
  })
  let with_endorse := router.route_effectful(with_ebl, "POST", "/tradefinance/ebl/:ref/endorse", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let to_holder := jstr(j, "to_holder")
        let by := jstr(j, "by")
        if str.is_empty(to_holder) or str.is_empty(by) {
          resp.bad_request("{\"error\":\"to_holder and by are required\"}")
        } else {
          match ebl_for(db, ref) {
            None => resp.json_status(404, "{\"error\":\"unknown eBL\"}"),
            Some(e) => if str.cmp(by, e.holder) != 0 {
              resp.json_status(403, str.concat("{\"error\":\"only the current holder may endorse (holder: ", str.concat(e.holder, ")\"}")))
            } else {
              match sql.exec(db, "UPDATE tf_ebl SET holder = ?, status = 'endorsed' WHERE ebl_ref = ? AND holder = ?", [PStr(to_holder), PStr(ref), PStr(by)]) {
                Err(er) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(er.message)), "}"))),
                Ok(n) => if n == 0 {
                  resp.json_status(409, "{\"error\":\"eBL was endorsed concurrently\"}")
                } else {
                  let log := settlement.trail_on(db)
                  let payload := jv.stringify(JObj([("ebl_ref", JStr(ref)), ("from_holder", JStr(by)), ("to_holder", JStr(to_holder))]))
                  let __x := tlog.append(log, "tradefinance.ebl.endorsed", chain_tip(db, "tradefinance.ebl.", "ebl_ref", ref), payload)
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("ebl_ref", JStr(ref)), ("holder", JStr(to_holder)), ("status", JStr("endorsed"))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_ebl_get := router.route_effectful(with_endorse, "GET", "/tradefinance/ebl/:ref", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match ebl_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"unknown eBL\"}"),
      Some(e) => resp.json(jv.stringify(JObj([("ebl_ref", JStr(ref)), ("shipper", JStr(e.shipper)), ("consignee", JStr(e.consignee)), ("carrier", JStr(e.carrier)), ("goods", JStr(e.goods)), ("trailer_ref", JStr(e.trailer_ref)), ("holder", JStr(e.holder)), ("status", JStr(e.status)), ("endorsements", JList(events_for(db, "tradefinance.ebl.", "ebl_ref", ref)))]))),
    }
  })
  let with_lc := router.route_effectful(with_ebl_get, "POST", "/tradefinance/lc", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let ref := jstr(j, "lc_ref")
        let applicant := jstr(j, "applicant")
        let beneficiary := jstr(j, "beneficiary")
        let required := jlist_str(j, "required_documents")
        if str.is_empty(ref) or str.is_empty(applicant) or str.is_empty(beneficiary) or list.is_empty(required) {
          resp.bad_request("{\"error\":\"lc_ref, applicant, beneficiary and a non-empty required_documents list are required\"}")
        } else {
          match money.parse(jdec(j, "amount_eur"), Eur, HalfUp(())) {
            None => resp.bad_request("{\"error\":\"amount_eur must be a decimal amount\"}"),
            Some(am) => {
              let amount_dec := money.format(am)
              let bank := jstr(j, "issuing_bank")
              let docs_csv := str.join(required, ",")
              let stmt := "INSERT INTO tf_lc (lc_ref, applicant, beneficiary, issuing_bank, amount_dec, required_docs, status, created_ms) VALUES (?, ?, ?, ?, ?, ?, 'open', ?) ON CONFLICT (lc_ref) DO NOTHING"
              match sql.exec(db, stmt, [PStr(ref), PStr(applicant), PStr(beneficiary), PStr(bank), PStr(amount_dec), PStr(docs_csv), PInt(time.now_ms())]) {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e.message)), "}"))),
                Ok(_) => {
                  let log := settlement.trail_on(db)
                  let payload := jv.stringify(JObj([("lc_ref", JStr(ref)), ("applicant", JStr(applicant)), ("beneficiary", JStr(beneficiary)), ("issuing_bank", JStr(bank)), ("amount_dec", JStr(amount_dec)), ("required_documents", JList(list.map(required, fn (d :: Str) -> jv.Json {
                    JStr(d)
                  })))]))
                  let __x := tlog.append(log, "tradefinance.lc.opened", None, payload)
                  resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("lc_ref", JStr(ref)), ("amount_dec", JStr(amount_dec)), ("required_documents", JList(list.map(required, fn (d :: Str) -> jv.Json {
                    JStr(d)
                  }))), ("status", JStr("open"))])))
                },
              }
            },
          }
        }
      },
    }
  })
  let with_lc_doc := router.route_effectful(with_lc, "POST", "/tradefinance/lc/:ref/documents", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match jv.parse(c.body) {
      Err(_) => resp.bad_request("{\"error\":\"invalid json\"}"),
      Ok(j) => {
        let doc_type := jstr(j, "doc_type")
        let hash := jstr(j, "hash")
        if str.is_empty(doc_type) or str.is_empty(hash) {
          resp.bad_request("{\"error\":\"doc_type and hash are required\"}")
        } else {
          match lc_for(db, ref) {
            None => resp.json_status(404, "{\"error\":\"unknown LC\"}"),
            Some(_) => {
              let log := settlement.trail_on(db)
              let ev := evidence.record(log, "tradefinance.lc.document", jstr(j, "by"), chain_tip(db, "tradefinance.lc.", "lc_ref", ref), [("lc_ref", JStr(ref)), ("doc_type", JStr(doc_type)), ("hash", JStr(hash)), ("by", JStr(jstr(j, "by")))])
              match ev {
                Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
                Ok(x) => resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("lc_ref", JStr(ref)), ("doc_type", JStr(doc_type)), ("event_id", JStr(x.id))]))),
              }
            },
          }
        }
      },
    }
  })
  let with_lc_settle := router.route_effectful(with_lc_doc, "POST", "/tradefinance/lc/:ref/settle", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match lc_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"unknown LC\"}"),
      Some(lc) => if str.cmp(lc.status, "settled") == 0 {
        resp.json_status(200, jv.stringify(JObj([("ok", JBool(true)), ("already_settled", JBool(true)), ("lc_ref", JStr(ref)), ("paid_dec", JStr(lc.paid_dec)), ("chargeback", JStr(lc.chargeback))])))
      } else {
        let required := split_docs(lc.required_docs)
        let missing := missing_docs(required, docs_presented(db, ref))
        if not list.is_empty(missing) {
          resp.json_status(409, jv.stringify(JObj([("error", JStr("documents incomplete: the LC cannot be honored")), ("missing_documents", JList(list.map(missing, fn (d :: Str) -> jv.Json {
            JStr(d)
          })))])))
        } else {
          let log := settlement.trail_on(db)
          let intact := match chain_tip(db, "tradefinance.lc.", "lc_ref", ref) {
            None => true,
            Some(tip) => settlement.verify(log, tip),
          }
          if not intact {
            resp.json_status(409, "{\"error\":\"document chain failed verification: the LC cannot be honored\"}")
          } else {
            match settlement.record_chargeback_dec(log, lc.applicant, lc.beneficiary, lc.amount_dec, "EUR", ref) {
              Err(e) => resp.json_status(500, str.concat("{\"error\":", str.concat(jv.stringify(JStr(e)), "}"))),
              Ok(cb_id) => {
                match sql.exec(db, "UPDATE tf_lc SET status = 'settled', paid_dec = ?, chargeback = ? WHERE lc_ref = ?", [PStr(lc.amount_dec), PStr(cb_id), PStr(ref)]) {
                  Err(e) => resp.json_status(500, jv.stringify(JObj([("error", JStr(str.concat("chargeback ", str.concat(cb_id, str.concat(" settled but LC record update failed — reconcile manually: ", e.message)))))]))),
                  Ok(_) => {
                    let payload := jv.stringify(JObj([("lc_ref", JStr(ref)), ("from_agent", JStr(lc.applicant)), ("to_agent", JStr(lc.beneficiary)), ("amount_dec", JStr(lc.amount_dec)), ("documents", JList(list.map(required, fn (d :: Str) -> jv.Json {
                      JStr(d)
                    }))), ("chargeback", JStr(cb_id))]))
                    let __e := tlog.append(log, "tradefinance.lc.settled", chain_tip(db, "tradefinance.lc.", "lc_ref", ref), payload)
                    resp.json_status(201, jv.stringify(JObj([("ok", JBool(true)), ("lc_ref", JStr(ref)), ("beneficiary", JStr(lc.beneficiary)), ("paid_dec", JStr(lc.amount_dec)), ("documents", JInt(list.len(required))), ("chargeback", JStr(cb_id))])))
                  },
                }
              },
            }
          }
        }
      },
    }
  })
  router.route_effectful(with_lc_settle, "GET", "/tradefinance/lc/:ref", fn (c :: ctx.Ctx) -> [io, time, crypto, random, sql, fs_read, fs_write, net, concurrent, llm, proc] resp.Response {
    let ref := match ctx.path_param(c, "ref") {
      Some(s) => s,
      None => "",
    }
    match lc_for(db, ref) {
      None => resp.json_status(404, "{\"error\":\"unknown LC\"}"),
      Some(lc) => {
        let required := split_docs(lc.required_docs)
        let have := docs_presented(db, ref)
        let missing := missing_docs(required, have)
        resp.json(jv.stringify(JObj([("lc_ref", JStr(ref)), ("applicant", JStr(lc.applicant)), ("beneficiary", JStr(lc.beneficiary)), ("issuing_bank", JStr(lc.issuing_bank)), ("amount_dec", JStr(lc.amount_dec)), ("status", JStr(lc.status)), ("required_documents", JList(list.map(required, fn (d :: Str) -> jv.Json {
          JStr(d)
        }))), ("presented_documents", JList(list.map(have, fn (d :: Str) -> jv.Json {
          JStr(d)
        }))), ("missing_documents", JList(list.map(missing, fn (d :: Str) -> jv.Json {
          JStr(d)
        }))), ("paid_dec", JStr(lc.paid_dec)), ("events", JList(events_for(db, "tradefinance.lc.", "lc_ref", ref)))])))
      },
    }
  })
}

# The domain vocabulary this pack speaks, in the engine's position words
# (lex-soft/src/positions). This pack carries two instruments, so it names more
# parties than the others: the title side (holder under sole control) and the
# documentary-credit side (paid against presented documents).
fn manifest() -> pos.PackManifest {
  { id: "tradefinance", title: "Trade finance", tagline: "An exclusive title moves under sole control; credit pays against documents that re-verify.", pattern: "title_transfer", subject: "instrument", subject_ref_field: "ebl_ref", custody_ref_field: "trailer_ref", parties: [{ position: "originator", name: "shipper", title: "Shipper — issues the title document", field: "shipper", required: true }, { position: "custodian", name: "holder", title: "Holder — the only party that may endorse it onward", field: "holder", required: true }, { position: "custodian", name: "consignee", title: "Consignee — entitled to take delivery at the end of the chain", field: "consignee", required: false }, { position: "executor", name: "carrier", title: "Carrier — performs the carriage the title is against", field: "carrier", required: false }, { position: "originator", name: "applicant", title: "Applicant — opens the credit", field: "applicant", required: false }, { position: "executor", name: "beneficiary", title: "Beneficiary — performs and is paid on presentation", field: "beneficiary", required: false }, { position: "settler", name: "issuing_bank", title: "Issuing bank — checks the documents and releases the funds", field: "issuing_bank", required: false }], relationships: [{ from: "shipper", to: "carrier", role: "contracted", label: "the carriage the title is issued against" }, { from: "shipper", to: "holder", role: "custody", label: "title is issued to its first holder" }, { from: "holder", to: "consignee", role: "custody", label: "endorsed onward until the consignee takes delivery" }, { from: "applicant", to: "issuing_bank", role: "contracted", label: "the applicant opens the credit" }, { from: "beneficiary", to: "issuing_bank", role: "reporting", label: "documents are presented for checking" }, { from: "issuing_bank", to: "beneficiary", role: "settlement", label: "the bank pays against conforming documents" }], event_kinds: ["tradefinance.ebl.issued", "tradefinance.ebl.endorsed", "tradefinance.lc.opened", "tradefinance.lc.document", "tradefinance.lc.settled"], evidence_kinds: ["document"], settles: true, route_prefix: "/tradefinance" }
}

