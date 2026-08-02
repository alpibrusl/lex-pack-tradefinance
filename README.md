# lex-pack-tradefinance

Trade-finance domain pack — electronic bill of lading (title transfer over lex-pack-custody) + letter-of-credit evidence-gated payment.

> **Status: scaffold.** This pack is being extracted from [`lex-ev-fleet`](https://github.com/alpibrusl/lex-ev-fleet) — see [https://github.com/alpibrusl/lex-ev-fleet/issues/237](https://github.com/alpibrusl/lex-ev-fleet/issues/237) for the extraction plan and what still needs to move here. Depends on lex-pack-custody — extract that one first.

## Layering

Part of the lex-soft pack family: `lex-soft` (engine) -> this pack (one vertical's routes + `pack.DomainPack`) -> [`lex-soft-node`](https://github.com/alpibrusl/lex-soft-node) (mounts a configured set of packs into a running deployment).

## License

Matches the rest of the lex ecosystem.
