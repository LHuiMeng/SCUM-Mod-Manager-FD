# Secrets

This directory is the only repository location allowed to contain sensitive
development material. Real secret files are ignored by Git.

Tracked files:

- `README.md`
- `example.toml`

Ignored examples:

- `runtime.toml`: local cloud endpoints, auth tokens, or developer credentials.
- `cloud-infrastructure.private.md`: real account, tunnel, DNS, and host mappings.
- `cloudflare-scum-mods-gate.wrangler.toml`: deployable Worker config with the
  real custom-domain hostname.
- `update.key`: private signing key used for release updates.
- `build.toml`: local packaging credentials.

Never expose these values through the web frontend or browser storage.
Runtime user secrets are stored as DPAPI-protected data under the app's
`app-data/secrets` directory next to the program executable. The program must
run from a writable directory outside `Program Files`.

Server installers bundle `runtime.toml` as a build resource. Public
installers never include it, and the Rust backend ignores `[cloud].auth_token`
when compiled as the public edition.

Both editions require `[cloud].base_urls` when producing a release build. The
public build embeds only the validated directory URLs at compile time so the
first launch is ready to use; it never embeds or bundles the shared token.

The repository tracks only `README.md` and `example.toml` from this directory.
Everything else, including nested files, is local-only.
