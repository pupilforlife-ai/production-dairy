import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type { AppRole, ApprovalStatus } from '../../core/auth/auth.models';
import type { ManagedUser } from './user-management.models';

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
}
