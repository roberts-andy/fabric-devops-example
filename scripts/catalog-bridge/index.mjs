#!/usr/bin/env node
/**
 * Sandbox catalog bridge (Option B).
 *
 * Reads `Requested` rows from the Fabric SQL catalog that the Rayfin portal
 * writes, opens a GitHub issue for each in the EXACT format that
 * `scripts/parse_workspace_request.py` expects, applies the
 * `fabric-workspace-request` label (which triggers `request-workspace.yml`),
 * then writes the issue number/URL back and flips the row to `Submitted`.
 *
 * This keeps the Rayfin backend CRUD-only: no server-side secrets or resolvers.
 * The bridge runs on a schedule in GitHub Actions with an Entra token, so the
 * portal never needs a GitHub credential. (Option C — submitting directly as
 * the signed-in user via GitHub OAuth — can be layered on later in the app's
 * `submit.ts` seam without removing this bridge.)
 *
 * Every table/column name is env-overridable because the exact SQL identifiers
 * Rayfin generates are only confirmable after `rayfin up db apply`. Defaults
 * match the entity property names in `app/rayfin/data/SandboxRequest.ts`.
 */
import mssql from 'mssql';

const {
  SQL_SERVER,
  SQL_DATABASE,
  SQL_ACCESS_TOKEN,
  SQL_PORT = '1433',
  GITHUB_TOKEN,
  GITHUB_REPOSITORY,
  GITHUB_API_URL = 'https://api.github.com',
  ISSUE_LABEL = 'fabric-workspace-request',
  CATALOG_SCHEMA = 'dbo',
  CATALOG_TABLE = 'sandbox_requests',
  MAX_BATCH = '25',
  DRY_RUN = 'false',
} = process.env;

// Column names — override any that differ from the deployed DDL.
const COL = {
  id: process.env.COL_ID || 'id',
  workspaceName: process.env.COL_WORKSPACE_NAME || 'workspaceName',
  workspaceKey: process.env.COL_WORKSPACE_KEY || 'workspaceKey',
  sandboxType: process.env.COL_SANDBOX_TYPE || 'sandboxType',
  ownerObjectId: process.env.COL_OWNER_OBJECT_ID || 'ownerObjectId',
  ttlDays: process.env.COL_TTL_DAYS || 'ttlDays',
  purpose: process.env.COL_PURPOSE || 'purpose',
  status: process.env.COL_STATUS || 'status',
  githubIssueNumber: process.env.COL_GH_ISSUE_NUMBER || 'githubIssueNumber',
  githubIssueUrl: process.env.COL_GH_ISSUE_URL || 'githubIssueUrl',
  createdAt: process.env.COL_CREATED_AT || 'createdAt',
  processedAt: process.env.COL_PROCESSED_AT || 'processedAt',
};

const SLUG_RE = /^[a-z][a-z0-9-]{2,39}$/;
const UUID_RE = /^[0-9a-fA-F-]{36}$/;
const dryRun = String(DRY_RUN).toLowerCase() === 'true';

function requireEnv(name, value) {
  if (!value) {
    console.error(`Missing required environment variable: ${name}`);
    process.exit(1);
  }
}

const q = (id) => `[${String(id).replace(/]/g, ']]')}]`;
const table = `${q(CATALOG_SCHEMA)}.${q(CATALOG_TABLE)}`;

/** Build the issue body in the exact shape parse_workspace_request.py expects. */
function issueBody(row) {
  const kind = row[COL.sandboxType];
  const ownerType = kind === 'team' ? 'Group' : 'User';
  const block = (heading, value) => `### ${heading}\n\n${value}\n`;
  return [
    block('Workspace name', row[COL.workspaceName]),
    block('Workspace key', row[COL.workspaceKey]),
    block('Sandbox type', kind),
    block('Owner principal type', ownerType),
    block('Owner Entra object ID', row[COL.ownerObjectId]),
    block('TTL in days', String(row[COL.ttlDays])),
    block('Business purpose', row[COL.purpose] || '_No response_'),
  ].join('\n');
}

/** Local pre-validation mirrors the parser so we don't open issues that fail. */
function validate(row) {
  const errors = [];
  const kind = row[COL.sandboxType];
  if (!SLUG_RE.test(row[COL.workspaceKey] || '')) errors.push('workspaceKey must match ^[a-z][a-z0-9-]{2,39}$');
  if (kind !== 'team' && kind !== 'personal') errors.push('sandboxType must be team or personal');
  if (!UUID_RE.test(row[COL.ownerObjectId] || '')) errors.push('ownerObjectId must be a UUID');
  const ttl = Number(row[COL.ttlDays]);
  if (!Number.isInteger(ttl) || ttl < 1 || ttl > 90) errors.push('ttlDays must be 1-90');
  return errors;
}

async function createIssue(row) {
  const title = `[sandbox] ${row[COL.workspaceName]} (${row[COL.workspaceKey]})`;
  const res = await fetch(`${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/issues`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ title, body: issueBody(row), labels: [ISSUE_LABEL] }),
  });
  if (!res.ok) {
    throw new Error(`GitHub issue create failed (${res.status}): ${await res.text()}`);
  }
  const issue = await res.json();
  return { number: issue.number, url: issue.html_url };
}

async function main() {
  requireEnv('SQL_SERVER', SQL_SERVER);
  requireEnv('SQL_DATABASE', SQL_DATABASE);
  requireEnv('SQL_ACCESS_TOKEN', SQL_ACCESS_TOKEN);
  requireEnv('GITHUB_TOKEN', GITHUB_TOKEN);
  requireEnv('GITHUB_REPOSITORY', GITHUB_REPOSITORY);

  const pool = await mssql.connect({
    server: SQL_SERVER,
    port: Number(SQL_PORT),
    database: SQL_DATABASE,
    authentication: {
      type: 'azure-active-directory-access-token',
      options: { token: SQL_ACCESS_TOKEN },
    },
    options: { encrypt: true, trustServerCertificate: false },
  });

  const selectSql =
    `SELECT TOP (${Number(MAX_BATCH)}) ` +
    [COL.id, COL.workspaceName, COL.workspaceKey, COL.sandboxType, COL.ownerObjectId, COL.ttlDays, COL.purpose]
      .map(q)
      .join(', ') +
    ` FROM ${table} WHERE ${q(COL.status)} = 'Requested' ORDER BY ${q(COL.createdAt)} ASC`;

  const { recordset } = await pool.request().query(selectSql);
  console.log(`Found ${recordset.length} Requested row(s).${dryRun ? ' (dry run)' : ''}`);

  let submitted = 0;
  let skipped = 0;
  for (const row of recordset) {
    const id = row[COL.id];
    const errors = validate(row);
    if (errors.length) {
      console.warn(`Skipping ${id} (${row[COL.workspaceKey]}): ${errors.join('; ')}`);
      skipped += 1;
      if (!dryRun) {
        await pool
          .request()
          .input('id', mssql.NVarChar, id)
          .query(`UPDATE ${table} SET ${q(COL.status)} = 'Failed', ${q(COL.processedAt)} = SYSUTCDATETIME() ` +
                 `WHERE ${q(COL.id)} = @id AND ${q(COL.status)} = 'Requested'`);
      }
      continue;
    }

    if (dryRun) {
      console.log(`[dry run] would open issue for ${row[COL.workspaceKey]}`);
      continue;
    }

    const { number, url } = await createIssue(row);
    await pool
      .request()
      .input('id', mssql.NVarChar, id)
      .input('num', mssql.Int, number)
      .input('url', mssql.NVarChar, url)
      .query(
        `UPDATE ${table} SET ${q(COL.status)} = 'Submitted', ${q(COL.githubIssueNumber)} = @num, ` +
          `${q(COL.githubIssueUrl)} = @url, ${q(COL.processedAt)} = SYSUTCDATETIME() ` +
          `WHERE ${q(COL.id)} = @id AND ${q(COL.status)} = 'Requested'`,
      );
    console.log(`Opened #${number} for ${row[COL.workspaceKey]} -> ${url}`);
    submitted += 1;
  }

  await pool.close();
  console.log(`Done. submitted=${submitted} skipped=${skipped}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
