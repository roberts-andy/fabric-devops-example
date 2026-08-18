import {
  createSandboxRequest,
  type NewSandboxRequest,
  type SandboxRequestItem,
} from './sandboxRequests';
import type { AuthUser } from './IAuthService';

export interface SubmitResult {
  request: SandboxRequestItem;
  /** True when a GitHub issue was opened during submit (Option C only). */
  issueOpened: boolean;
}

/**
 * Submit a sandbox request. This is the single seam the UI depends on, so the
 * submission strategy can change without touching the page.
 *
 * Option B (current): persist a `Requested` row in the Fabric catalog and
 * return. A scheduled GitHub Actions bridge reads new rows out-of-band and
 * opens the labelled issue that triggers provisioning. The browser never
 * calls GitHub, so no token is exposed in the static frontend.
 *
 * Option C (future): a GitHub-OAuth submitter can additionally open the issue
 * in-session as the signed-in user. To add it later, branch here on config,
 * open the issue after `createSandboxRequest`, set `issueOpened: true`, and
 * fill `githubIssueNumber` / `githubIssueUrl` on the returned request — the
 * page and catalog table already render those fields.
 */
export async function submitSandboxRequest(
  input: NewSandboxRequest,
  user: AuthUser
): Promise<SubmitResult> {
  const request = await createSandboxRequest(input, user.email);
  return { request, issueOpened: false };
}
