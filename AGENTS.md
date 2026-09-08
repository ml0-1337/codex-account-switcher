# codex-account-switcher

The project and Swift package are named `codex-account-switcher`; the only command-line executable is `codex-switch`. It does not bundle a GUI or OpenAI binaries.

- Keep credential persistence and file switching in `Sources/CodexSwitchCore`; the executable owns terminal interaction only.
- Never quit, restart, modify, or send account-switch notifications to the official application. Only terminate login children owned by this CLI.
- Normal switching and recovery do not start Codex or use the network. Login uses the signed official application's bundled Codex in a private temporary home for new accounts.
- Preserve state v2 and Keychain record v1. New switch journals use v3 and registration journals use v2. Refuse legacy pending records instead of interpreting them as new operations.
- Never put real credentials, account lists, private keys, or machine-specific user paths in this repository or test output.
- Use synthetic credentials and private temporary directories for automated tests. Real Keychain/browser/application acceptance is manual and requires separate authorization; follow [docs/manual-acceptance.md](docs/manual-acceptance.md). No default test may operate on the user's credentials or official app.
- Use TDD for changed behavior. Run focused tests during development, then `scripts/check.sh` on the stable candidate. Distribution and acceptance instructions live in `README.md`.
- Keep local implementation separate from installation and publication. Do not replace a user's existing CLI, push, publish, or release without a separate request.
