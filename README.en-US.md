# FileCodeBox

**Anonymous code-based file & text sharing — like picking up a parcel.** Upload, get a pickup code, share the code; the recipient enters the code and downloads. No registration required.

FileCodeBox is the Go multirepo workspace of the [filescodebox](https://github.com/orgs/filescodebox/repositories) organization. This repository is the **umbrella (hub)**: no business code, only tooling to assemble the module repos into a buildable workspace.

## Repositories

| Repo | Role | Version |
|------|------|---------|
| [contracts](https://github.com/filescodebox/contracts) | Contract layer: error codes + Thrift-generated types (zero business deps) | v0.1.0 |
| [core](https://github.com/filescodebox/core) | Business core library: 10 domain services + repo/storage + `bootstrap.Bootstrap()` | v0.2.0 |
| [server](https://github.com/filescodebox/server) | Deployable app: thin main + static frontend + Dockerfile | follows core |
| [frontend](https://github.com/filescodebox/frontend) | Vue3 + TS + Vite + Element Plus | - |
| [filecodebox-fnos](https://github.com/filescodebox/filecodebox-fnos) | fnOS (fnNAS) adapter (optional) | v0.1.1 |
| [charts](https://github.com/filescodebox/charts) | Kubernetes Helm chart | chart 0.1.0 |

Dependency direction (CI-enforced): `server / fnos / frontend ──► core ──► contracts`

## Highlights

- **Share text or files anonymously** with pickup codes, expiry by time and/or download count, optional access password (bcrypt).
- **Chunked uploads** with resume + instant upload (SHA-256 dedup) + presigned direct upload.
- **Storage backends**: local disk, S3-compatible (AWS/MinIO/OSS/COS/B2…), WebDAV — hot-switchable at runtime, persisted across restarts.
- **Admin console**: dashboard, file/user management, audit log, site config persisted in DB, transfer logs.
- **User system**: quotas, API keys, notifications (in-app + webhook).
- **Ops-ready**: Prometheus metrics, OpenTelemetry tracing (opt-in), health checks, Helm chart with ServiceMonitor, multi-arch images.
- Light by design: a parcel locker, not a cloud drive.

## Quick start

```bash
docker compose up -d          # or: BUILD=1 docker compose up -d
```

Open `http://localhost:12345`. Default admin is `admin / admin123` — override with `FCB_ADMIN_PASSWORD` in production.

Build from source:

```bash
git clone https://github.com/filescodebox/FileCodeBox.git && cd FileCodeBox
make setup     # fetch module repos (idempotent)
make test      # Go tests + frontend typecheck
make build     # workspace build → bin/
make smoke     # boot server & smoke-test
```

## Documentation

- Architecture (Mermaid): [docs/architecture.md](docs/architecture.md)
- Roadmap: [ROADMAP.md](ROADMAP.md) · Changelog: [CHANGELOG.md](CHANGELOG.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · Security policy: [SECURITY.md](SECURITY.md)
- Environment variables: see `docs/` in the server repo / legacy docs (being consolidated)

## License

[MIT](LICENSE) © The FileCodeBox Authors
