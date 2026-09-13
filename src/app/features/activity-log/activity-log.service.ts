import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type { ActivityEvent } from './activity-log.models';

@Injectable({ providedIn: 'root' })
export class ActivityLogService {
  private readonly supabase = inject(SupabaseService).client;

  async listRecent(limit = 150): Promise<ActivityEvent[]> {
    const { data, error } = await this.supabase.rpc('list_activity_events', {
      requested_limit: limit,
    });
    if (error) throw error;
    return data as ActivityEvent[];
  }
}
