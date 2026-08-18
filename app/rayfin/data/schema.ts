import { SandboxRequest } from './SandboxRequest.js';

export type PortalSchema = {
  SandboxRequest: SandboxRequest;
};

export const schema = [SandboxRequest];
