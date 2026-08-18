import { getRayfinClient, isLocalBackend } from './rayfinClient';

export type SandboxType = 'team' | 'personal';
export type SandboxStatus = 'Requested' | 'Submitted' | 'Provisioned' | 'Failed';

export interface SandboxRequestItem {
  id: string;
  workspaceName: string;
  workspaceKey: string;
  sandboxType: SandboxType;
  ownerObjectId: string;
  ttlDays: number;
  purpose: string;
  requester: string;
  status: SandboxStatus;
  githubIssueNumber?: number;
  githubIssueUrl?: string;
  createdAt: Date;
  processedAt?: Date;
}

/** The fields the intake form collects; everything else is derived server-side. */
export interface NewSandboxRequest {
  workspaceName: string;
  workspaceKey: string;
  sandboxType: SandboxType;
  ownerObjectId: string;
  ttlDays: number;
  purpose: string;
}

const SELECT_FIELDS = [
  'id',
  'workspaceName',
  'workspaceKey',
  'sandboxType',
  'ownerObjectId',
  'ttlDays',
  'purpose',
  'requester',
  'status',
  'githubIssueNumber',
  'githubIssueUrl',
  'createdAt',
  'processedAt',
] as const;

// Local-dev fallback: when no Fabric backend is configured, keep the catalog
// in memory so the portal is fully clickable without a database.
const inMemory: SandboxRequestItem[] = [];

export async function getSandboxRequests(): Promise<SandboxRequestItem[]> {
  if (isLocalBackend()) {
    return [...inMemory].sort(
      (a, b) => b.createdAt.getTime() - a.createdAt.getTime()
    );
  }

  const client = getRayfinClient();
  const results = await client.data.SandboxRequest.select([...SELECT_FIELDS])
    .orderBy({ createdAt: 'desc' })
    .execute();
  return results as SandboxRequestItem[];
}

export async function createSandboxRequest(
  input: NewSandboxRequest,
  requester: string
): Promise<SandboxRequestItem> {
  const record = {
    ...input,
    requester,
    status: 'Requested' as const,
    createdAt: new Date(),
  };

  if (isLocalBackend()) {
    const item: SandboxRequestItem = { id: crypto.randomUUID(), ...record };
    inMemory.push(item);
    return item;
  }

  const client = getRayfinClient();
  const session = client.auth.getSession();
  if (!session.isAuthenticated || !session.user) {
    throw new Error('Cannot create request: user is not authenticated.');
  }
  const created = await client.data.SandboxRequest.create(record);
  return created as SandboxRequestItem;
}
