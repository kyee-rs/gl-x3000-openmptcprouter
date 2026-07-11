# Contributing

Keep changes narrowly scoped and reproducible:

1. Preserve pinned upstream revisions unless the pull request explicitly
   updates and revalidates them.
2. Require patches to apply with zero fuzz.
3. Keep modem provisioning, carrier settings, and private overlays outside the
   repository.
4. Never commit binaries, firmware images, packages, build trees, logs, router
   backups, factory data, or credentials.
5. Run `make lint`, the offline validator after a build, and
   `scripts/public-release-preflight.sh` before opening a pull request.
6. Label hardware observations separately from upstream facts and hypotheses.

When reporting runtime behavior, include only sanitized source revisions,
topology, bounded error excerpts, and RX/TX evidence. Do not publish subscriber
or unit-specific identifiers.
