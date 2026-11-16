# Releasing meum

Each release has its notes here as `<version>.md`, committed before the release is tagged; they become the GitHub
release's text.

Releases are built on the maintainer's Mac: `scripts/release.sh <version> --publish`, with `MEUM_RELEASE_GATE` set,
runs the release checks (clean tree, VERSION and the plugin manifest, these notes, the zmx wire protocol, the MeumKit
and control API interfaces) and the gate, builds, smoke-tests, signs and notarizes, pushes one commit with the
release's tree to `main` of mcurses/meum with the tag `v<version>` on it, and publishes the release with the DMG.

`.github/workflows/release.yml` can do the build, signing and notarizing on GitHub instead, but it starts only by
hand and has no signing secrets yet; a pushed tag starts nothing.

## Who may create a release tag

Not set yet: a tag ruleset that limits creating, moving and deleting `v*` tags to the repository's admin (its owner).
It matters before the workflow's tag trigger comes back. Set once by the owner, with their login:

```sh
gh api -X POST repos/mcurses/meum/rulesets --input - <<'EOF'
{
  "name": "release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [ { "type": "creation" }, { "type": "update" }, { "type": "deletion" } ],
  "bypass_actors": [ { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" } ]
}
EOF
```

(`actor_id` 5 is the Admin repository role.) Check it with `gh api repos/mcurses/meum/rulesets`, or in the browser
under Settings ▸ Rules ▸ Rulesets.

Requiring signatures (the `required_signatures` rule) would also need the release commit to be signed:
`scripts/release.sh` makes it with `git commit-tree`, so that waits until the Mac has a git signing key and the
script passes `-S`.
