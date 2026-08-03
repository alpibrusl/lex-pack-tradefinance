# tests/test_tradefinance.lex — pure-logic coverage for src/tradefinance.lex.
#
# split_docs/missing_docs are the pure, non-trivial functions here (parsing
# the stored CSV of required documents, and diffing required against
# presented); the effectful routes (eBL, LC, settlement, DB) need a live DB
# to exercise meaningfully — that's covered by lex-ev-fleet's own
# integration testing of the mounted deployment.

import "std.list" as list

import "lex-soft/src/positions" as pos

import "../src/tradefinance" as tradefinance

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

# ---- split_docs ---------------------------------------------------------------
fn test_split_docs_splits_on_comma() -> Result[Unit, Str] {
  let got := tradefinance.split_docs("invoice,packing_list,bol")
  assert_true(list.len(got) == 3 and list.head(got) == Some("invoice"), "a comma-separated list must split into its documents")
}

fn test_split_docs_drops_blank_entries() -> Result[Unit, Str] {
  let got := tradefinance.split_docs("invoice,,bol")
  assert_true(list.len(got) == 2, "an empty entry between commas must be dropped, not kept as a blank document")
}

fn test_split_docs_empty_string_is_empty_list() -> Result[Unit, Str] {
  assert_true(list.is_empty(tradefinance.split_docs("")), "an empty string must split into no documents")
}

# ---- missing_docs ---------------------------------------------------------------
fn test_missing_docs_none_missing() -> Result[Unit, Str] {
  assert_true(list.is_empty(tradefinance.missing_docs(["invoice", "bol"], ["invoice", "bol"])), "when every required document is presented, nothing is missing")
}

fn test_missing_docs_reports_what_is_missing() -> Result[Unit, Str] {
  let got := tradefinance.missing_docs(["invoice", "bol"], ["invoice"])
  assert_true(got == ["bol"], "an unpresented required document must be named as missing")
}

fn test_missing_docs_ignores_surrounding_whitespace() -> Result[Unit, Str] {
  assert_true(list.is_empty(tradefinance.missing_docs(["invoice"], [" invoice "])), "presented documents must match required ones regardless of surrounding whitespace")
}

# ---- manifest() -------------------------------------------------------------
fn test_manifest_is_valid() -> Result[Unit, Str] {
  let m := tradefinance.manifest()
  assert_true(list.is_empty(pos.validate(m)), "tradefinance's own manifest must satisfy the shared position/pattern validator")
}

fn test_manifest_route_prefix() -> Result[Unit, Str] {
  assert_true(tradefinance.manifest().route_prefix == "/tradefinance", "manifest route_prefix must match the mounted routes")
}

fn test_manifest_settles() -> Result[Unit, Str] {
  assert_true(tradefinance.manifest().settles, "the LC side pays against documents, so the manifest must declare settles: true")
}

fn run_all() -> List[Result[Unit, Str]] {
  [test_split_docs_splits_on_comma(), test_split_docs_drops_blank_entries(), test_split_docs_empty_string_is_empty_list(), test_missing_docs_none_missing(), test_missing_docs_reports_what_is_missing(), test_missing_docs_ignores_surrounding_whitespace(), test_manifest_is_valid(), test_manifest_route_prefix(), test_manifest_settles()]
}

