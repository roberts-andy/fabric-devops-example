import { entity, role, text, int, set, date, uuid } from '@microsoft/rayfin-core';

export type SandboxType = 'team' | 'personal';
export type SandboxStatus = 'Requested' | 'Submitted' | 'Provisioned' | 'Failed';

/**
 * A request for an ephemeral Microsoft Fabric sandbox workspace.
 *
 * This is the shared catalog behind the portal. Rows are written by the
 * intake form (status `Requested`) and later picked up by the scheduled
 * GitHub Actions bridge, which opens the labelled issue that drives the
 * existing provisioning automation and writes the issue number/URL back.
 *
 * `@role('authenticated', '*')` with no policy makes this a *shared* catalog:
 * any signed-in user sees and manages every request. That keeps the demo
 * simple. For per-user isolation you would add a policy like the template's
 * `(claims, item) => claims.sub.eq(item.requesterId)`.
 */
@entity()
@role('authenticated', '*')
export class SandboxRequest {
  @uuid() id!: string;

  /** Friendly Fabric display name, e.g. "SBX - Marketing Forecast". */
  @text({ min: 3, max: 60 }) workspaceName!: string;

  /** Slug used by the automation: ^[a-z][a-z0-9-]{2,39}$ */
  @text({ min: 3, max: 40 }) workspaceKey!: string;

  @set('team', 'personal') sandboxType!: SandboxType;

  /** Entra object ID of the owning group (team) or user (personal). */
  @text({ min: 36, max: 36 }) ownerObjectId!: string;

  @int({ min: 1, max: 90, default: 30 }) ttlDays!: number;

  @text({ min: 1, max: 500 }) purpose!: string;

  /** Email of the person who filed the request (from the session). */
  @text({ max: 120 }) requester!: string;

  @set({ default: 'Requested' }, 'Requested', 'Submitted', 'Provisioned', 'Failed')
  status!: SandboxStatus;

  /** Populated by the bridge once the GitHub issue is opened. */
  @int({ optional: true }) githubIssueNumber?: number;
  @text({ optional: true, max: 400 }) githubIssueUrl?: string;

  @date() createdAt!: Date;

  /** When the bridge last acted on this row. */
  @date({ optional: true }) processedAt?: Date;
}
