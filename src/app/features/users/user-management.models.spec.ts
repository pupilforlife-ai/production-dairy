import { describe, expect, it } from 'vitest';
import {
  countUsersByStatus,
  validatePasswordReset,
  type ManagedUser,
} from './user-management.models';

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

describe('owner password reset validation', () => {
  it('requires at least eight characters', () => {
    expect(validatePasswordReset('short', 'short')).toBe(
      'The new password must contain at least 8 characters.',
    );
  });

  it('requires matching confirmation', () => {
    expect(validatePasswordReset('new-password', 'different-password')).toBe(
      'The password confirmation does not match.',
    );
  });

  it('accepts matching passwords without returning the password', () => {
    expect(validatePasswordReset('new-password', 'new-password')).toBeNull();
  });
});
