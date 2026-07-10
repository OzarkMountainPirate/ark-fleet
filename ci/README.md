# Self-hosted CI (Woodpecker)

Self-hosted lint for `ark-fleet`. Assumes a host with: `proxy` network,
your wildcard TLS (Option B `tls.domains` labels), Cloudflare tunnel.

## Which runner?

**Your repo is on GitHub, so GitHub Actions is the zero-infra default** — the
`.github/workflows/lint.yml` in the repo root works with no self-hosted daemon.
Woodpecker is here because you want CI in-house; the tradeoff is one OAuth app +
two containers to keep an eye on. Same three linters either way. Run one, not both.

## Stand up Woodpecker

```bash
cp .env.example .env
$EDITOR .env                      # OAuth client/secret + agent secret
# add a DNS route for <CI_HOST> through your tunnel config.yml (like codex),
# and a Pi-hole split-horizon record if you want LAN-direct access.
sudo docker compose up -d
sudo docker compose logs -f woodpecker-server
```

Then in the UI at https://<CI_HOST>: log in via GitHub, enable the
`ark-fleet` repo. Every push runs `.woodpecker.yml` (yamllint, ansible-lint,
shellcheck). Red build = don't deploy.

## Socket-proxy hardening (optional, matches your posture)

The agent needs the Docker API to spawn pipeline steps. The compose bind-mounts
the socket directly for simplicity. To route it through a Tecnativa socket-proxy
like your other stacks, the agent requires `CONTAINERS=1 IMAGES=1 POST=1
EXEC=1 INFO=1` (it creates, execs, and waits on step containers) and
`WOODPECKER_DOCKER_HOST=tcp://socket-proxy:2375`.
