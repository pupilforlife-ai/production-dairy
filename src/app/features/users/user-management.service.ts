import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type { AppRole, ApprovalStatus } from '../../core/auth/auth.models';
import type { ManagedUser } from './user-management.models';
import type { OwnerUserActionResult } from './user-management.models';

@Injectable({ providedIn: 'root' })
export class UserManagementService {
  private readonly supabase = inject(SupabaseService).client;

  async listUsers(): Promise<ManagedUser[]> {
    const { data, error } = await this.supabase.rpc('list_app_users');
    if (error) throw error;
    return data as ManagedUser[];
  }

  async updateUser(userId: string, status: ApprovalStatus, role: AppRole): Promise<void> {
    const { error } = await this.supabase.rpc('manage_app_user', {
      requested_user_id: userId,
      requested_status: status,
      requested_role: role,
    });
    if (error) throw error;
  }

  async resetPassword(userId: string, password: string): Promise<void> {
    await this.runOwnerAction({ action: 'reset_password', userId, password });
  }

  async deleteUser(userId: string): Promise<void> {
    await this.runOwnerAction({ action: 'delete_user', userId });
  }

  private async runOwnerAction(body: Record<string, string>): Promise<void> {
    const { data: sessionData, error: sessionError } = await this.supabase.auth.refreshSession();
    if (sessionError || !sessionData.session) {
      throw new Error('Your session has expired. Please sign in again, then retry the password change.');
    }

    const { data, error } = await this.supabase.functions.invoke<OwnerUserActionResult>(
      'owner-user-admin',
      { body },
    );

    if (error) {
      const response = (error as { context?: Response }).context;
      if (response) {
        let payload: { error?: string } | null = null;
        try {
          payload = (await response.clone().json()) as { error?: string };
        } catch {
          // Use the SDK error when the function did not return JSON.
        }
        if (payload?.error) throw new Error(payload.error);
      }
      throw error;
    }

    if (!data?.ok) throw new Error(data?.message ?? 'The owner action could not be completed.');
  }
}
