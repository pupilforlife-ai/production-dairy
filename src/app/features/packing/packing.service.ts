import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  CompletePackingInput,
  FinishedStockLot,
  PackingData,
  PackingLocation,
  PackingRunSummary,
  PackingSku,
  PackingSourceLot,
} from './packing.models';

@Injectable({ providedIn: 'root' })
export class PackingService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<PackingData> {
    const [skusResult, sourcesResult, locationsResult, runsResult, finishedResult] =
      await Promise.all([
        this.supabase
          .from('skus')
          .select(
            'id, product_id, code, description, unit_weight_g, pieces_per_packet, products(name, variant), packaging_configs(packets_per_case, nominal_case_weight_kg, variable_case_allowed, effective_from, effective_to)',
          )
          .eq('active', true)
          .order('code'),
        this.supabase
          .from('intermediate_lots')
          .select(
            'id, product_id, lot_code, display_label, current_quantity, produced_at, source_transformation_id, products(code, name, variant), units_of_measure(code), storage_locations(id, code, name), production_batches(batch_code, round_number, source_lots(lot_code), production_shifts(shift_number))',
          )
          .eq('status', 'available')
          .gt('current_quantity', 0)
          .order('produced_at'),
        this.supabase
          .from('storage_locations')
          .select('id, code, name')
          .eq('active', true)
          .eq('code', 'FINISHED_PRODUCTION'),
        this.supabase
          .from('packing_runs')
          .select(
            'id, completed_at, operator_team, cases_produced, loose_units_produced, packets_per_case_used, total_packet_equivalent, input_quantity_kg, actual_packed_weight_kg, yield_variance_kg, fifo_overridden, fifo_override_reason, skus(code, description), packing_run_sources(quantity_consumed, intermediate_lots(lot_code))',
          )
          .eq('status', 'completed')
          .order('completed_at', { ascending: false })
          .limit(30),
        this.supabase
          .from('finished_stock_lots')
          .select(
            'id, lot_code, case_quantity, loose_unit_quantity, packet_equivalent, current_packet_quantity, packed_weight_kg, status, produced_at, skus(code, description), storage_locations(name)',
          )
          .order('produced_at', { ascending: false })
          .limit(100),
      ]);

    for (const result of [skusResult, sourcesResult, locationsResult, runsResult, finishedResult]) {
      if (result.error) throw result.error;
    }

    return {
      skus: skusResult.data as unknown as PackingSku[],
      sourceLots: sourcesResult.data as unknown as PackingSourceLot[],
      locations: locationsResult.data as unknown as PackingLocation[],
      packingRuns: runsResult.data as unknown as PackingRunSummary[],
      finishedLots: finishedResult.data as unknown as FinishedStockLot[],
    };
  }

  async completePacking(input: CompletePackingInput): Promise<void> {
    const { error } = await this.supabase.rpc('complete_packing_run', {
      requested_sku_id: input.skuId,
      requested_completed_at: new Date(input.completedAt).toISOString(),
      requested_operator_team: input.operatorTeam,
      requested_cases: input.cases,
      requested_loose_units: input.looseUnits,
      requested_packets_per_case_override: input.packetsPerCaseOverride,
      requested_actual_packed_weight_kg: input.actualPackedWeightKg,
      requested_sources: input.sources.map((source) => ({
        intermediate_lot_id: source.intermediateLotId,
        quantity: source.quantity,
      })),
      requested_fifo_override_reason: input.fifoOverrideReason,
      requested_weight_variance_reason: input.weightVarianceReason,
      requested_wrappers_used: input.wrappersUsed,
      requested_cases_used: input.casesUsed,
      requested_destination_location_id: input.destinationLocationId,
      requested_notes: input.notes,
    });
    if (error) throw error;
  }
}
