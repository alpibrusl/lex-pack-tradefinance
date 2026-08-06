# info.lex — the tradefinance agent-domain manifest (pack.PackInfo).
#
# The DomainPack counterpart of this pack's REST pos.PackManifest: how a
# console should PRESENT the tradefinance-ops persona — label, tagline,
# starter prompts. Served by the host under /platform/packs's agent_packs
# field.

import "lex-soft/src/pack" as pack

fn info() -> pack.PackInfo {
  { name: "tradefinance", title: "Trade finance", tagline: "eBL title transfer under sole-control endorsement, and letters of credit paid only against verified evidence.", personas: [{ kind: "tradefinance-ops", title: "Trade finance ops", tagline: "Issues and endorses eBLs, and opens, evidences, and settles letters of credit.", suggested_prompts: ["Issue an eBL ref BL-100 for shipper acme-exports to consignee acme-imports.", "Endorse eBL BL-100 to holder freight-forwarder-1 as acme-exports.", "Open a letter of credit LC-100 for applicant acme-imports, beneficiary acme-exports, 10000 EUR, requiring a bill_of_lading and an inspection_certificate.", "Present the bill_of_lading document for LC-100.", "Settle letter of credit LC-100."] }] }
}

