import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  DashboardMilkLot,
  DashboardProductionBatch,
  LatestMilkDashboardData,
} from './dashboard.models';

@Injectable({ providedIn: 'root' })
export class DashboardService {
  private readonly supabase = inject(SupabaseService).client;

  async loadLatestMilk(): Promise<LatestMilkDashboardData> {
    const { data: milkLot, error: milkError } = await this.supabase
      .from('source_lots')
      .select('id, lot_code, received_at, received_quantity, status, units_of_measure(code)')
      .eq('lot_type', 'milk')
      .in('status', ['accepted', 'closed'])
      .order('received_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (milkError) throw milkError;
    if (!milkLot) return { milkLot: null, batches: [] };

    const { data: batches, error: batchError } = await this.supabase
      .from('production_batches')
      .select(
        'id, round_number, actual_primary_input_quantity, gross_output_quantity, status, products(name, variant), production_shifts(id, shift_number, started_at, shift_members(person_name))',
      )
      .eq('parent_source_lot_id', milkLot.id)
      .neq('status', 'cancelled')
      .order('round_number');
    if (batchError) throw batchError;

    return {
      milkLot: milkLot as unknown as DashboardMilkLot,
      batches: batches as unknown as DashboardProductionBatch[],
    };
  }
}
