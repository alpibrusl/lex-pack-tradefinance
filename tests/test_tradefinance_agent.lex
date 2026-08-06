# tests/test_tradefinance_agent.lex — pure-logic coverage for
# src/tradefinance_agent.lex.
#
# lex test discards run_all's return value and only checks whether the call
# raises a runtime error -- see lex-ag-ui's README for the full writeup.
# This file forces a real runtime error when count_failures(...) > 0 so
# lex test/lex ci are real gates here.

import "std.list" as list

import "lex-schema/json_value" as jv

import "lex-schema/schema" as sch

import "lex-llm/src/tool" as t

import "../src/tradefinance_agent" as agent

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    Err(label)
  }
}

fn schema_of(name :: Str) -> Option[sch.ModelSchema] {
  match t.find_by_name(agent.make_tradefinance_tools("http://127.0.0.1:8100"), name) {
    None => None,
    Some(tool) => Some(tool.params),
  }
}

fn test_seven_tools_defined() -> Result[Unit, Str] {
  assert_true(list.len(agent.make_tradefinance_tools("http://127.0.0.1:8100")) == 7, "tradefinance has exactly 7 REST routes today, so exactly 7 tools should be defined")
}

fn test_issue_ebl_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("ebl_ref", JStr("BL-100")), ("shipper", JStr("acme-exports")), ("consignee", JStr("acme-imports"))])
  match schema_of("issue_ebl") {
    None => Err("issue_ebl tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("issue_ebl's schema must accept tradefinance.lex's documented POST /tradefinance/ebl body"),
      Ok(_) => pass(),
    },
  }
}

fn test_endorse_ebl_schema_requires_to_holder() -> Result[Unit, Str] {
  let bad := JObj([("ebl_ref", JStr("BL-100")), ("by", JStr("acme-exports"))])
  match schema_of("endorse_ebl") {
    None => Err("endorse_ebl tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("endorse_ebl's schema must require to_holder"),
    },
  }
}

fn test_open_letter_of_credit_schema_accepts_documented_shape() -> Result[Unit, Str] {
  let sample := JObj([("lc_ref", JStr("LC-100")), ("applicant", JStr("acme-imports")), ("beneficiary", JStr("acme-exports")), ("amount_eur", JFloat(10000.0)), ("required_documents", JList([JStr("bill_of_lading"), JStr("inspection_certificate")]))])
  match schema_of("open_letter_of_credit") {
    None => Err("open_letter_of_credit tool must be defined"),
    Some(schema) => match sch.validate(schema, sample) {
      Err(_) => Err("open_letter_of_credit's schema must accept tradefinance.lex's documented POST /tradefinance/lc body"),
      Ok(_) => pass(),
    },
  }
}

fn test_present_lc_document_schema_requires_hash() -> Result[Unit, Str] {
  let bad := JObj([("lc_ref", JStr("LC-100")), ("doc_type", JStr("bill_of_lading"))])
  match schema_of("present_lc_document") {
    None => Err("present_lc_document tool must be defined"),
    Some(schema) => match sch.validate(schema, bad) {
      Err(_) => pass(),
      Ok(_) => Err("present_lc_document's schema must require hash"),
    },
  }
}

fn test_settle_letter_of_credit_schema_requires_lc_ref() -> Result[Unit, Str] {
  match schema_of("settle_letter_of_credit") {
    None => Err("settle_letter_of_credit tool must be defined"),
    Some(schema) => match sch.validate(schema, JObj([])) {
      Err(_) => pass(),
      Ok(_) => Err("settle_letter_of_credit's schema must require lc_ref"),
    },
  }
}

fn suite_pure() -> List[Result[Unit, Str]] {
  [test_seven_tools_defined(), test_issue_ebl_schema_accepts_documented_shape(), test_endorse_ebl_schema_requires_to_holder(), test_open_letter_of_credit_schema_accepts_documented_shape(), test_present_lc_document_schema_requires_hash(), test_settle_letter_of_credit_schema_requires_lc_ref()]
}

fn count_failures(results :: List[Result[Unit, Str]]) -> Int {
  list.fold(results, 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

fn run_all() -> Int {
  let failures := count_failures(suite_pure())
  let _crash_if_failed := if failures > 0 {
    1 / 0
  } else {
    0
  }
  failures
}

