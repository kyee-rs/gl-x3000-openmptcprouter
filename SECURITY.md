# Security and privacy

Please report security issues privately through GitHub's security-advisory
feature rather than a public issue.

Do not attach router backups, configuration exports, modem dumps, factory or
calibration partitions, private logs, credentials, SIM identifiers, device
identifiers, private endpoints, or signing material to any issue or pull
request. Reproduce a problem with sanitized summaries and placeholders.

Every contribution should pass:

```sh
make lint
scripts/public-release-preflight.sh
```

The preflight is deliberately fail-closed and requires `gitleaks` in addition
to filename and pattern checks.
