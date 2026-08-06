# tradefinance_agent.lex — an LLM-driven agent persona that operates THIS
# pack's own REST service (tradefinance.lex's /tradefinance/* routes).
#
# Same loopback-HTTP pattern as lex-pack-construction/src/construction_agent.lex.
# Tradefinance has no external backend to wrap (no outbound HTTP calls
# anywhere in tradefinance.lex) -- its mount() IS the domain logic.

import "std.str" as str

import "std.http" as http

import "std.map" as map

import "std.bytes" as bytes

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-schema/error" as e

import "lex-spec/capability" as cap

import "lex-llm/src/tool" as t

import "lex-agent/src/server" as srv

import "lex-agent/src/agent_card" as card

import "lex-soft/src/runner" as runner

fn http_post_json(url :: Str, body :: Str, tenant :: Str) -> [net] jv.Json {
  let req0 := { method: "POST", url: url, headers: map.new(), body: Some(bytes.from_str(body)), timeout_ms: Some(30000) }
  let req1 := http.with_header(req0, "Content-Type", "application/json")
  let req := if str.is_empty(tenant) {
    req1
  } else {
    http.with_header(req1, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(b) => match jv.parse(b) {
        Err(_) => JStr(b),
        Ok(j) => j,
      },
    },
  }
}

fn http_get_json(url :: Str, tenant :: Str) -> [net] jv.Json {
  let base := { method: "GET", url: url, headers: map.new(), body: None, timeout_ms: Some(30000) }
  let req := if str.is_empty(tenant) {
    base
  } else {
    http.with_header(base, "X-Tenant-Id", tenant)
  }
  match http.send(req) {
    Err(_) => JObj([("error", JStr("unreachable")), ("url", JStr(url))]),
    Ok(resp) => match bytes.to_str(resp.body) {
      Err(_) => JObj([("error", JStr("decode error"))]),
      Ok(body) => match jv.parse(body) {
        Err(_) => JStr(body),
        Ok(j) => j,
      },
    },
  }
}

fn jstr(j :: jv.Json, key :: Str) -> Str {
  match jv.get_field(j, key) {
    Some(JStr(s)) => s,
    _ => "",
  }
}

# ── Capability ────────────────────────────────────────────────────────────────
fn tradefinance_capability() -> cap.Capability {
  cap.inbound("handle", "Operate trade-finance instruments: issue and endorse an electronic bill of lading, and open, evidence, and settle a letter of credit.", { title: "TradefinanceOps", description: "Inbound message for the tradefinance ops agent.", fields: [sch.required_str("text", [])] })
}

# ── Tools (self — this pack's own REST routes, no external backend) ──────────
fn make_tradefinance_tools(self_base_url :: Str) -> List[t.Tool] {
  [t.define("issue_ebl", "Issue an electronic bill of lading naming the shipper, consignee and (optionally) carrier and goods description. The shipper becomes the initial holder.", { title: "IssueEbl", description: "eBL issuance.", fields: [sch.required_str("ebl_ref", []), sch.required_str("shipper", []), sch.required_str("consignee", []), sch.optional(sch.required_str("carrier", [])), sch.optional(sch.required_str("goods", [])), sch.optional(sch.required_str("trailer_ref", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/tradefinance/ebl"), jv.stringify(args), ""))
  }), t.define("endorse_ebl", "Transfer title of an eBL to a new holder. Only the current holder can endorse.", { title: "EndorseEbl", description: "eBL endorsement.", fields: [sch.required_str("ebl_ref", []), sch.required_str("to_holder", []), sch.required_str("by", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/tradefinance/ebl/", jstr(args, "ebl_ref"), "/endorse"], ""), jv.stringify(args), ""))
  }), t.define("get_ebl_status", "Check an eBL's current holder and its full endorsement chain before acting on it.", { title: "GetEblStatus", description: "eBL status lookup.", fields: [sch.required_str("ebl_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(self_base_url, str.concat("/tradefinance/ebl/", jstr(args, "ebl_ref"))), ""))
  }), t.define("open_letter_of_credit", "Open a letter of credit naming the applicant, beneficiary, amount, and the documents required before it can be settled.", { title: "OpenLetterOfCredit", description: "LC issuance.", fields: [sch.required_str("lc_ref", []), sch.required_str("applicant", []), sch.required_str("beneficiary", []), sch.optional(sch.required_str("issuing_bank", [])), sch.required_float("amount_eur", []), sch.required_array("required_documents", KStr([]), [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.concat(self_base_url, "/tradefinance/lc"), jv.stringify(args), ""))
  }), t.define("present_lc_document", "Present one required document (by type and content hash) as evidence against a letter of credit.", { title: "PresentLcDocument", description: "LC document presentation.", fields: [sch.required_str("lc_ref", []), sch.required_str("doc_type", []), sch.required_str("hash", []), sch.optional(sch.required_str("by", []))] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/tradefinance/lc/", jstr(args, "lc_ref"), "/documents"], ""), jv.stringify(args), ""))
  }), t.define("get_lc_status", "Check a letter of credit's status: presented vs. missing documents, and whether it has been paid. Check this before attempting to settle.", { title: "GetLcStatus", description: "LC status lookup.", fields: [sch.required_str("lc_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_get_json(str.concat(self_base_url, str.concat("/tradefinance/lc/", jstr(args, "lc_ref"))), ""))
  }), t.define("settle_letter_of_credit", "Settle a letter of credit: pays the beneficiary iff every required document has been presented and the evidence chain verifies. Idempotent -- settling an already-settled LC replays the prior result.", { title: "SettleLetterOfCredit", description: "LC settlement.", fields: [sch.required_str("lc_ref", [])] }, fn (args :: jv.Json) -> [net, io, proc] Result[jv.Json, e.Errors] {
    Ok(http_post_json(str.join([self_base_url, "/tradefinance/lc/", jstr(args, "lc_ref"), "/settle"], ""), jv.stringify(args), ""))
  })]
}

# ── System prompt ──────────────────────────────────────────────────────────────
fn tradefinance_system_prompt(id :: Str) -> Str {
  str.join(["You are trade-finance ops agent ", id, ". You operate two instruments: an electronic bill of lading (eBL) that transfers title to goods by endorsement, and a letter of credit (LC) that pays a beneficiary only once every required document is presented and verified.", " Use issue_ebl/endorse_ebl/get_ebl_status for the eBL side, and open_letter_of_credit/present_lc_document/get_lc_status/settle_letter_of_credit for the LC side. Always check status before endorsing or settling, and explain exactly what document is missing if a settlement is refused.", " Be precise about ebl_ref and lc_ref, and always name the specific instrument you acted on."], "")
}

# ── Agent factory (the persona builder the pack mounts) ────────────────────────
fn make_tradefinance_def(db :: Db, id :: Str, base_url :: Str, self_base_url :: Str, provider_name :: Str, provider_url :: Str, provider_key :: Str, model_name :: Str) -> srv.AgentDef {
  let capability := tradefinance_capability()
  let cfg := { id: id, kind: "tradefinance-ops", system_prompt: tradefinance_system_prompt(id), model_name: model_name, provider_name: provider_name, provider_url: provider_url, provider_key: provider_key, backends: [{ key: "self_url", url: self_base_url }], intent_roles: [], tools: make_tradefinance_tools(self_base_url) }
  let handler := runner.make_handler(db, cfg)
  let c := card.make(id, str.concat("Trade-finance ops agent ", id), "0.1.0", base_url, [capability])
  srv.make_agent_def(c, [{ capability: capability, handle: handler }])
}

