import { describe, expect, it } from 'vitest';
import { countUsersByStatus, type ManagedUser } from './user-management.models';

describe('user management summaries', () => {
  it('counts each approval status', () => {
    const users = [
      { approval_status: 'pending' },
      { approval_status: 'approved' },
      { approval_status: 'approved' },
      { approval_status: 'disapproved' },
    ] as ManagedUser[];

    expect(countUsersByStatus(users)).toEqual({ pending: 1, approved: 2, disapproved: 1 });
  });
});
