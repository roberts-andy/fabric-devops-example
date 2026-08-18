# Fabric Sandbox Portal

A small [Microsoft Fabric App (Rayfin, preview)](https://learn.microsoft.com/en-us/fabric/apps/overview)
that gives users a friendly front door to the self-service sandbox automation in the
root of this repository.

It does three things:

1. **Collects** a sandbox request from a signed-in user (Fabric SSO).
2. **Stores** every request in a Fabric SQL catalog so there is a durable, queryable
   inventory of who asked for what.
3. **Hands off** to the existing GitHub automation — a scheduled
   [catalog bridge](../scripts/catalog-bridge/) opens a labelled GitHub issue for each
   new request, which triggers `request-workspace.yml` and provisions the workspace.

```text
User ─▶ Rayfin portal ─▶ Fabric SQL catalog ──(scheduled bridge)──▶ GitHub issue ─▶ request-workspace.yml ─▶ Fabric workspace
             (writes a SandboxRequest row)         reads Requested rows        labelled fabric-workspace-request
```

## Why this shape?

Rayfin's generated backend is **CRUD-only** — the `@entity()` model auto-generates a
Fabric SQL database, a GraphQL API, row-level security, and Fabric SSO, but there is no
place to run server-side code or hold a GitHub secret. So the portal never talks to
GitHub directly. Instead it just writes catalog rows, and a scheduled GitHub Actions job
(which already has federated Azure credentials) reads those rows and does the privileged
work. This keeps the demo simple and keeps every credential on the automation side.

> **Option C (later):** submitting the GitHub issue directly as the signed-in user via
> GitHub OAuth is a natural add. The single UI submission seam lives in
> [`src/services/submit.ts`](src/services/submit.ts) — swap the implementation there and
> the rest of the app is unchanged. The catalog bridge can stay as a backstop.

## Project layout

```text
app/
  rayfin/data/
    SandboxRequest.ts   # the catalog entity (13 fields, shared authenticated role)
    schema.ts           # PortalSchema = [SandboxRequest]
  src/
    pages/HomePage.tsx        # intake form + catalog table
    pages/AuthPage.tsx        # Fabric sign-in
    services/
      sandboxRequests.ts      # catalog CRUD (get + create) w/ in-memory fallback
      submit.ts               # single UI submission seam (Option C extension point)
      rayfinClient.ts         # typed Rayfin client
    __tests__/                # in-memory service tests
```

## Local development

Requires Node in one of Rayfin's supported ranges (`>=20 <21 || >=22 <23 || >=24 <25`).
This repo was validated on **Node 24.19.0**.

```bash
cd app
npm install
npm run test      # unit tests (in-memory, no cloud)
npm run lint
npm run build     # tsc -b && vite build
```

`npm run dev` starts Rayfin's local emulator plus Vite. Use `npm run build` (not a bare
`tsc --noEmit`) for type-checking, because build mode regenerates the compiled Rayfin
artifacts.

## Deploy to Fabric

```bash
cd app
rayfin login              # interactive browser sign-in (Fabric Apps preview must be enabled)
rayfin up --dry-run       # preview the plan
rayfin up                 # create the app, SQL database, and static frontend
```

After the first `rayfin up db apply`, **confirm the generated SQL table and column
names** and feed them into the bridge's environment variables (see
[`scripts/catalog-bridge/`](../scripts/catalog-bridge/) and
[`docs/portal.md`](../docs/portal.md)). The bridge defaults to the entity property names;
override any that differ.

See [`docs/portal.md`](../docs/portal.md) for the full architecture, the service-principal
and database-grant steps, and the GitHub variables the bridge needs.
