import { describe, expect, it, beforeEach, vi } from 'vitest';

vi.mock('@/services/rayfinClient', () => ({
  isLocalBackend: () => true,
  getRayfinClient: vi.fn(),
}));

import {
  createSandboxRequest,
  getSandboxRequests,
  type NewSandboxRequest,
} from '@/services/sandboxRequests';

const sample: NewSandboxRequest = {
  workspaceName: 'Marketing Forecast Sandbox',
  workspaceKey: 'marketing-forecast',
  sandboxType: 'team',
  ownerObjectId: '11111111-1111-1111-1111-111111111111',
  ttlDays: 30,
  purpose: 'Explore Fabric for the forecast pipeline.',
};

describe('sandboxRequests service (in-memory mode)', () => {
  beforeEach(() => {
    // Reset the module-level in-memory store between tests.
    vi.resetModules();
  });

  it('creates a request with derived defaults', async () => {
    const created = await createSandboxRequest(sample, 'user@contoso.com');
    expect(created.id).toBeTruthy();
    expect(created.status).toBe('Requested');
    expect(created.requester).toBe('user@contoso.com');
    expect(created.createdAt).toBeInstanceOf(Date);
  });

  it('lists created requests newest-first', async () => {
    await createSandboxRequest(sample, 'user@contoso.com');
    await createSandboxRequest(
      { ...sample, workspaceKey: 'second-sandbox' },
      'user@contoso.com'
    );

    const all = await getSandboxRequests();
    expect(all.length).toBeGreaterThanOrEqual(2);
    // Newest first.
    expect(all[0]?.createdAt.getTime()).toBeGreaterThanOrEqual(
      all[1]?.createdAt.getTime() ?? 0
    );
  });
});
