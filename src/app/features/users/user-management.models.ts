import type { AppRole, ApprovalStatus } from '../../core/auth/auth.models';

export interface ManagedUser {
  id: string;
  email: string;
  display_name: string;
  role: AppRole;
  approval_status: ApprovalStatus;
  active: boolean;
  registered_at: string;
  last_sign_in_at: string | null;
}

export interface UserDraft {
  role: AppRole;
  status: ApprovalStatus;
}

export const USER_ROLES: Array<{ value: AppRole; label: string }> = [
  { value: 'owner', label: 'Owner' },
  { value: 'admin', label: 'Admin' },
  { value: 'factory_worker', label: 'Factory Worker' },
];

export const USER_STATUSES: Array<{ value: ApprovalStatus; label: string }> = [
  { value: 'pending', label: 'Awaiting approval' },
  { value: 'approved', label: 'Approved' },
  { value: 'disapproved', label: 'Disapproved' },
];

export function countUsersByStatus(users: ManagedUser[]): Record<ApprovalStatus, number> {
  return users.reduce(
    (counts, user) => ({
      ...counts,
      [user.approval_status]: counts[user.approval_status] + 1,
    }),
    { pending: 0, approved: 0, disapproved: 0 },
  );
}
