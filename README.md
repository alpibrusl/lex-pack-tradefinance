# lex-pack-tradefinance

Trade-finance domain pack (v0 scaffold) — electronic bill of lading title transfer under sole-control endorsement, plus letter-of-credit evidence-gated payment.

Extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) (see [issue #237](https://github.com/alpibrusl/lex-ev-fleet/issues/237)). Builds on [`lex-pack-custody`](https://github.com/alpibrusl/lex-pack-custody) at the **data** level only: an eBL's `trailer_ref` names a custody chain in the shared `events` table — this pack does not import custody's code or depend on it in `lex.toml`. A deployment mounting both needs custody as its own dependency.

This is a v0 scaffold, not the regulated article: no MLETR conformance suite, no bank-rail settlement, no possession/transfer legal semantics beyond sole-control endorsement.

## Routes

```
POST /tradefinance/ebl                 — issue {ebl_ref, shipper, consignee, carrier, goods, trailer_ref}
POST /tradefinance/ebl/:ref/endorse    — transfer title {to_holder, by}: only the current holder may
GET  /tradefinance/ebl/:ref            — parties, current holder, endorsement chain
POST /tradefinance/lc                  — open {lc_ref, applicant, beneficiary, issuing_bank, amount_eur, required_documents:[..]}
POST /tradefinance/lc/:ref/documents   — present {doc_type, hash, by}
POST /tradefinance/lc/:ref/settle      — pay iff every required document proves AND the chain verifies
GET  /tradefinance/lc/:ref             — status, presented vs required, amount, paid
```

## Usage

```lex
import "lex-pack-tradefinance/tradefinance" as tradefinance

# in your router-wiring code:
let r := tradefinance.mount(router.new(), db)
```

`tradefinance.manifest()` returns the `pos.PackManifest` describing this pack's parties/pattern for the `lex-soft/src/positions` catalogue.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine, primitives) → this pack (`mount()` for the HTTP routes, `manifest()` for the `lex-soft/src/positions` catalogue) → [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License


Copyright (c) 2026 lex-pack-tradefinance contributors.

Licensed under the [EUPL-1.2](LICENSE) — the European Union Public Licence, as used across the `lex-*` ecosystem.

