# Licensing transition record — unreleased

Prepared November 1, 2026. This working-tree change is pending review and has
not been committed, pushed, tagged, or released. No first PolyForm release
version or transition commit has been assigned yet. Do not interpret existing
version numbers in this working tree as a relicensing of published artifacts.
Before publication, record the actual transition commit and first new release
here and complete the ordinary versioning, signing, and release gates.

## Authority and scope

The owner confirmed for this migration that all original project code and
documentation, excluding the declared third-party components, are owned by the
owner, without employer, customer, or other author rights. The requested
licensor and copyright identity is Sideswipe3751. This confirmation is the basis
for proceeding, not an inference from Git authorship. Contracting identity and
legal terms still need review before selling commercial licenses.

The original code in the post-transition tree is offered under the unchanged
PolyForm Noncommercial License 1.0.0 in `LICENSE`, with the licensor's required
notice in `NOTICE`, or under a separately executed commercial agreement.
Third-party components and upstream patch contexts are excluded from this
relicensing and retain their original terms and attribution.

## Preserved Apache record

The pre-transition default-branch tip is
`8dbe1c68358605ca6b0b31684a9ed0c9b6cf9dff`. Its default-branch history contains
22 commits under one recorded author identity, Sideswipe3751; no coauthor
trailers or pull requests were found in the audit. Git metadata alone does not
prove copyright ownership. The repository's contribution policy used Apache-2.0
and DCO, not a copyright assignment or commercial relicensing agreement.

`LICENSE-APACHE-2.0` preserves the pre-transition `LICENSE` text. All code already
made available under Apache-2.0 retains those grants, including commercial use
subject to its conditions, whether or not it was tagged. Existing copyright
and attribution notices remain applicable. This transition imposes no
retroactive fee or new restriction on rights already granted. It cannot prevent
continued commercial use or forks of the previously Apache-licensed code.

The following existing tags and their historical license records are unchanged:

- `v0.1-local-baseline`
- `v1.1.0-rc.1`, `v1.1.0-rc.2`, `v1.1.0-rc.3`
- `v2.0.0-alpha.1`, `v2.0.0-alpha.2`, `v2.0.0-alpha.3`, `v2.0.0-alpha.4`

The seven existing GitHub releases (`v1.1.0-rc.1` through
`v2.0.0-alpha.4`), their assets, signed manifests, checksums, and version pins
are not modified. Installed or downloaded historical packages keep their
original license. New legal metadata in this tree must not be used to overwrite
an existing release archive. A new release requires its own version and artifacts.

## Third-party boundary

`THIRD_PARTY_NOTICES.md`, provider locks, upstream license files, and dependency
metadata retain their original terms. Declared components include the two MIT
providers, Node.js, and CPython; provider dependencies also carry their own
licenses. A commercial BIM Bridge agreement does not grant Autodesk SDK rights
or override those dependencies' terms. Before distributing a new binary package,
verify its actual transitive dependency inventory and required notices; a
source-tree metadata audit is not a complete binary bill of materials.

## Remaining publication decisions

- Record the transition commit and first release after review; do not rewrite
  existing tags, releases, or history.
- Supply a working commercial licensing contact (currently TODO).
- Confirm full legal contracting identity, pricing, seat/device rules, support,
  upgrades, and redistribution scope in each commercial agreement.
- Have counsel review the contract, liability terms, and proposed British
  Columbia, Canada governing law before execution.
- Establish an explicit contributor agreement covering commercial licensing
  before merging external contributions into the dual-licensed original code.
- Verify all legal materials and third-party notices in a newly versioned
  package before release. No new archive is built or published by this migration.
