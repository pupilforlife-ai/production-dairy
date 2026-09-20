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
      .select(
        'id, lot_code, received_at, received_quantity, status, units_of_measure(code), source_lot_milk_sales(quantity)',
      )
      .eq('lot_type', 'milk')
      .in('status', ['accepted', 'closed'])
      .order('received_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (milkError) throw milkError;
    if (!milkLot) return { milkLot: null, batches: [], finishedLots: [], packingVerifications: [] };

    const { data: batches, error: batchError } = await this.supabase
      .from('production_batches')
      .select(
        'id, round_number, actual_primary_input_quantity, gross_output_quantity, status, products(name, variant), production_shifts(id, shift_number, started_at, shift_members(person_name)), production_round_blocks(weight_kg), production_round_packing_entries(cases, loose_packets, skus(code, description, unit_weight_g, products(name, variant), packaging_configs(packets_per_case, nominal_case_weight_kg)))',
      )
      .eq('parent_source_lot_id', milkLot.id)
      .neq('status', 'cancelled')
      .order('round_number');
    if (batchError) throw batchError;

    const { data: finishedLots, error: finishedError } = await this.supabase
      .from('finished_stock_lots')
      .select(
        'id, packed_weight_kg, current_packet_quantity, status, skus(code, description, products(name, variant))',
      )
      .gt('current_packet_quantity', 0)
      .neq('status', 'depleted')
      .order('produced_at', { ascending: false });
    if (finishedError) throw finishedError;

    const { data: packingVerifications, error: verificationError } = await this.supabase
      .from('production_sku_packing_verifications')
      .select(
        'id, corrected_cases, corrected_loose_packets, packets_per_case_used, case_weight_kg_used, distributed_cases, distributed_loose_packets, rejected_cases, rejected_loose_packets, status, skus(code, description, unit_weight_g, products(name, variant), packaging_configs(packets_per_case, nominal_case_weight_kg))',
      );
    if (verificationError) throw verificationError;

    return {
      milkLot: milkLot as unknown as DashboardMilkLot,
      batches: batches as unknown as DashboardProductionBatch[],
      finishedLots: finishedLots as unknown as LatestMilkDashboardData['finishedLots'],
      packingVerifications:
        packingVerifications as unknown as LatestMilkDashboardData['packingVerifications'],
    };
  }
}
