# ADR 0015: Unqualified builds remain usable

Decision requested by the maintainer on 2026-10-02. This supersedes the
unknown-build refusal in ADR 0001 and spec section 6.

The compatibility Ledger records evidence, rather than serving as a build
allowlist. A build or hardware model without qualification may act after the
Facility's runtime self checks and permission preflights pass. Its readiness
remains `unvalidated` and its Receipts keep `unvalidatedBuild: true`. No Ledger
entry is added or promoted by running a test.

Failed symbol resolution, invalid record layout, missing permissions and an
unreadable bundled Ledger still refuse. Debug and release use the same gate;
the former release-only unconditional authorization is removed. Window identity,
geometry, containment and observation admission continue to be verified at the
operation boundary. Global input is never a fallback.

Existing `allowUnvalidatedBuild` arguments and the research startup flag remain
source-compatible. They do not change this policy or lift runtime failures.
Restoring a stricter qualification requirement would be a separate policy change.
