import { useCallback, useEffect, useMemo, useState } from 'react';

import { useAuth } from '@/hooks/AuthContext';
import {
  getSandboxRequests,
  type SandboxRequestItem,
  type SandboxType,
} from '@/services/sandboxRequests';
import { submitSandboxRequest } from '@/services/submit';

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const SLUG_RE = /^[a-z][a-z0-9-]{2,39}$/;

function slugify(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .replace(/-{2,}/g, '-')
    .slice(0, 40);
}

const EMPTY_FORM = {
  workspaceName: '',
  workspaceKey: '',
  sandboxType: 'team' as SandboxType,
  ownerObjectId: '',
  ttlDays: 30,
  purpose: '',
};

export function HomePage() {
  const { signOut, user } = useAuth();
  const [requests, setRequests] = useState<SandboxRequestItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [form, setForm] = useState(EMPTY_FORM);
  const [keyEdited, setKeyEdited] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const fetchRequests = useCallback(async () => {
    const data = await getSandboxRequests();
    setRequests(data);
    setLoading(false);
  }, []);

  useEffect(() => {
    void fetchRequests();
  }, [fetchRequests]);

  // Keep the slug in sync with the name until the user edits it directly.
  const effectiveKey = keyEdited ? form.workspaceKey : slugify(form.workspaceName);

  const validation = useMemo(() => {
    const errors: Partial<Record<keyof typeof EMPTY_FORM, string>> = {};
    if (form.workspaceName.trim().length < 3)
      errors.workspaceName = 'At least 3 characters.';
    if (!SLUG_RE.test(effectiveKey))
      errors.workspaceKey =
        'Lowercase letters, numbers and hyphens; start with a letter; 3-40 chars.';
    if (!UUID_RE.test(form.ownerObjectId.trim()))
      errors.ownerObjectId = 'Must be an Entra object ID (a GUID).';
    if (form.ttlDays < 1 || form.ttlDays > 90)
      errors.ttlDays = 'Between 1 and 90 days.';
    if (form.purpose.trim().length < 1) errors.purpose = 'Required.';
    return errors;
  }, [form, effectiveKey]);

  const isValid = Object.keys(validation).length === 0;

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!isValid || !user) return;
    setSubmitting(true);
    setError(null);
    try {
      await submitSandboxRequest(
        {
          workspaceName: form.workspaceName.trim(),
          workspaceKey: effectiveKey,
          sandboxType: form.sandboxType,
          ownerObjectId: form.ownerObjectId.trim(),
          ttlDays: form.ttlDays,
          purpose: form.purpose.trim(),
        },
        user
      );
      setForm(EMPTY_FORM);
      setKeyEdited(false);
      await fetchRequests();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to submit request.');
    } finally {
      setSubmitting(false);
    }
  };

  const ownerLabel =
    form.sandboxType === 'team'
      ? 'Owner group (Entra object ID)'
      : 'Owner user (Entra object ID)';
  const ownerHint =
    form.sandboxType === 'team'
      ? 'The security group that will own this shared team workspace.'
      : 'The individual user who will own this personal sandbox.';

  return (
    <div className="bg-gray-50 min-h-screen">
      <header className="flex items-center justify-between px-8 py-5 bg-white border-b border-gray-200">
        <div>
          <h1 className="text-xl font-bold text-gray-900">Fabric Sandbox Portal</h1>
          <p className="text-xs text-gray-500">
            Request an ephemeral Microsoft Fabric workspace
          </p>
        </div>
        <div className="flex items-center gap-4">
          {user?.email && (
            <span className="text-sm text-gray-600" title={user.email}>
              {user.email}
            </span>
          )}
          <button
            onClick={() => void signOut()}
            className="text-gray-400 hover:text-gray-600 transition-colors text-sm"
            aria-label="Sign out"
          >
            Sign out
          </button>
        </div>
      </header>

      <main className="max-w-5xl mx-auto px-4 py-10 grid gap-10 lg:grid-cols-[minmax(0,380px)_1fr]">
        <section>
          <h2 className="text-sm font-semibold text-gray-900 mb-4">New request</h2>
          <form onSubmit={(e) => void handleSubmit(e)} className="space-y-4">
            <Field label="Workspace name" error={validation.workspaceName}>
              <input
                type="text"
                value={form.workspaceName}
                onChange={(e) =>
                  setForm((f) => ({ ...f, workspaceName: e.target.value }))
                }
                placeholder="Marketing Forecast Sandbox"
                className={inputClass}
              />
            </Field>

            <Field
              label="Workspace key"
              error={validation.workspaceKey}
              hint="Used by the automation as the slug. Auto-filled from the name."
            >
              <input
                type="text"
                value={effectiveKey}
                onChange={(e) => {
                  setKeyEdited(true);
                  setForm((f) => ({ ...f, workspaceKey: e.target.value }));
                }}
                placeholder="marketing-forecast"
                className={inputClass}
              />
            </Field>

            <Field label="Sandbox type">
              <select
                value={form.sandboxType}
                onChange={(e) =>
                  setForm((f) => ({
                    ...f,
                    sandboxType: e.target.value as SandboxType,
                  }))
                }
                className={inputClass}
              >
                <option value="team">Team (shared, owned by a group)</option>
                <option value="personal">Personal (owned by a user)</option>
              </select>
            </Field>

            <Field label={ownerLabel} error={validation.ownerObjectId} hint={ownerHint}>
              <input
                type="text"
                value={form.ownerObjectId}
                onChange={(e) =>
                  setForm((f) => ({ ...f, ownerObjectId: e.target.value }))
                }
                placeholder="00000000-0000-0000-0000-000000000000"
                className={inputClass}
              />
            </Field>

            <Field
              label="TTL (days)"
              error={validation.ttlDays}
              hint="Auto-expires after this many days (1-90)."
            >
              <input
                type="number"
                min={1}
                max={90}
                value={form.ttlDays}
                onChange={(e) =>
                  setForm((f) => ({ ...f, ttlDays: Number(e.target.value) }))
                }
                className={inputClass}
              />
            </Field>

            <Field label="Business purpose" error={validation.purpose}>
              <textarea
                value={form.purpose}
                onChange={(e) =>
                  setForm((f) => ({ ...f, purpose: e.target.value }))
                }
                rows={3}
                placeholder="What is this sandbox for?"
                className={inputClass}
              />
            </Field>

            {error && <p className="text-sm text-red-600">{error}</p>}

            <button
              type="submit"
              disabled={!isValid || submitting}
              className="w-full rounded-xl bg-blue-600 px-5 py-3 text-sm font-medium text-white shadow-sm transition-all hover:bg-blue-700 disabled:opacity-40"
            >
              {submitting ? 'Submitting...' : 'Submit request'}
            </button>
          </form>
        </section>

        <section>
          <h2 className="text-sm font-semibold text-gray-900 mb-4">
            Sandbox catalog ({requests.length})
          </h2>
          {loading ? (
            <p className="text-center text-gray-400 text-sm py-16">Loading...</p>
          ) : requests.length === 0 ? (
            <div className="text-center py-16">
              <p className="text-gray-400 text-sm">
                No requests yet. Submit one on the left.
              </p>
            </div>
          ) : (
            <div className="overflow-hidden rounded-xl border border-gray-200 bg-white">
              <table className="w-full text-sm">
                <thead>
                  <tr className="border-b border-gray-200 text-left text-xs uppercase tracking-wider text-gray-400">
                    <th className="px-4 py-3 font-semibold">Workspace</th>
                    <th className="px-4 py-3 font-semibold">Type</th>
                    <th className="px-4 py-3 font-semibold">TTL</th>
                    <th className="px-4 py-3 font-semibold">Status</th>
                    <th className="px-4 py-3 font-semibold">Issue</th>
                  </tr>
                </thead>
                <tbody>
                  {requests.map((r) => (
                    <tr key={r.id} className="border-b border-gray-100 last:border-0">
                      <td className="px-4 py-3">
                        <div className="font-medium text-gray-900">
                          {r.workspaceName}
                        </div>
                        <div className="text-xs text-gray-400">{r.workspaceKey}</div>
                      </td>
                      <td className="px-4 py-3 text-gray-600 capitalize">
                        {r.sandboxType}
                      </td>
                      <td className="px-4 py-3 text-gray-600">{r.ttlDays}d</td>
                      <td className="px-4 py-3">
                        <StatusBadge status={r.status} />
                      </td>
                      <td className="px-4 py-3">
                        {r.githubIssueUrl ? (
                          <a
                            href={r.githubIssueUrl}
                            target="_blank"
                            rel="noreferrer"
                            className="text-blue-600 hover:underline"
                          >
                            #{r.githubIssueNumber}
                          </a>
                        ) : (
                          <span className="text-gray-300">—</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </main>
    </div>
  );
}

const inputClass =
  'w-full rounded-xl border border-gray-300 bg-white px-4 py-2.5 text-sm text-gray-900 placeholder-gray-400 shadow-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500';

function Field({
  label,
  error,
  hint,
  children,
}: {
  label: string;
  error?: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-xs font-medium text-gray-700">{label}</span>
      {children}
      {hint && !error && (
        <span className="mt-1 block text-xs text-gray-400">{hint}</span>
      )}
      {error && <span className="mt-1 block text-xs text-red-600">{error}</span>}
    </label>
  );
}

const STATUS_STYLES: Record<string, string> = {
  Requested: 'bg-gray-100 text-gray-600',
  Submitted: 'bg-blue-100 text-blue-700',
  Provisioned: 'bg-green-100 text-green-700',
  Failed: 'bg-red-100 text-red-700',
};

function StatusBadge({ status }: { status: string }) {
  return (
    <span
      className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-medium ${
        STATUS_STYLES[status] ?? 'bg-gray-100 text-gray-600'
      }`}
    >
      {status}
    </span>
  );
}
