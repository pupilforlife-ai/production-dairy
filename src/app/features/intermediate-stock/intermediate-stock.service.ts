import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  IntermediateLotSummary,
  IntermediateStockData,
  ProductionBatchOption,
  RecordCuttingInput,
  StorageLocationOption,
  TransformationSummary,
} from './intermediate-stock.models';
import { buildPackingVerificationView } from '../packing-verification/packing-verification.models';
import type {
  PackedRoundEntry,
  PackingVerification,
  PackingVerificationSource,
} from '../packing-verification/packing-verification.models';

@Injectable({ providedIn: 'root' })
export class IntermediateStockService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<IntermediateStockData> {
    const [
      lotsResult,
      locationsResult,
      transformationsResult,
      batchesResult,
      packingEntriesResult,
      packingVerificationsResult,
      packingSourcesResult,
    ] = await Promise.all([
        this.supabase
          .from('intermediate_lots')
          .select(
            'id, product_id, source_batch_id, source_transformation_id, parent_intermediate_lot_id, lot_code, display_label, produced_quantity, current_quantity, status, produced_at, products(code, name, variant), units_of_measure(code), storage_locations(id, code, name), production_batches(batch_code, round_number, process_stage, cut_format, cut_by, cut_completed_at, status, products(variant), source_lots(lot_code), production_shifts(shift_number))',
          )
          .order('produced_at', { ascending: true }),
        this.supabase
          .from('storage_locations')
          .select('id, code, name, location_type')
          .eq('active', true)
          .in('code', ['PRODUCTION', 'CHILLER', 'INTERMEDIATE_FREEZER'])
          .order('name'),
        this.supabase
          .from('transformations')
          .select(
            'id, occurred_at, performed_by, cut_type, source_quantity, loss_quantity, loss_reason, notes, units_of_measure(code), production_batches(batch_code), transformation_outputs(id, output_kind, output_label, quantity, products(code, name), storage_locations(name))',
          )
          .eq('transformation_type', 'cutting')
          .eq('status', 'completed')
          .order('occurred_at', { ascending: false })
          .limit(25),
        this.supabase
          .from('production_batches')
          .select(
            'id, batch_code, round_number, actual_primary_input_quantity, gross_output_quantity, process_stage, process_stage_changed_at, cut_by, cut_format, cut_completed_at, cutting_allocation, status, products(code, name, variant), source_lots(lot_code), production_shifts(shift_number)',
          )
          .neq('status', 'cancelled')
          .order('created_at', { ascending: false })
          .limit(100),
        this.supabase
          .from('production_round_packing_entries')
          .select(
            'id, production_batch_id, sku_id, cases, loose_packets, recorded_at, production_batches(batch_code, round_number, products(name, variant), production_shifts(shift_number, shift_members(person_name))), skus(code, description, unit_weight_g, packaging_configs(packets_per_case, nominal_case_weight_kg, variable_case_allowed, effective_from, effective_to))',
          )
          .order('recorded_at', { ascending: false }),
        this.supabase
          .from('production_sku_packing_verifications')
          .select(
            'id, sku_id, declared_cases, declared_loose_packets, corrected_cases, corrected_loose_packets, packets_per_case_used, case_weight_kg_used, verified_packet_quantity, source_round_uncertain, correction_reason, distributed_cases, distributed_loose_packets, distributed_packet_quantity, retained_loose_packets, distribution_exception_reason, status, verified_at, sent_to_distribution_at',
          ),
        this.supabase
          .from('production_sku_packing_verification_sources')
          .select(
            'verification_id, packing_entry_id, production_batch_id, declared_cases, declared_loose_packets',
          ),
      ]);

    for (const result of [
      lotsResult,
      locationsResult,
      transformationsResult,
      batchesResult,
      packingEntriesResult,
      packingVerificationsResult,
      packingSourcesResult,
    ]) {
      if (result.error) throw result.error;
    }

    const packingView = buildPackingVerificationView(
      packingEntriesResult.data as unknown as PackedRoundEntry[],
      packingVerificationsResult.data as unknown as PackingVerification[],
      packingSourcesResult.data as unknown as PackingVerificationSource[],
    );

    return {
      lots: lotsResult.data as unknown as IntermediateLotSummary[],
      locations: locationsResult.data as unknown as StorageLocationOption[],
      transformations: transformationsResult.data as unknown as TransformationSummary[],
      productionBatches: batchesResult.data as unknown as ProductionBatchOption[],
      packedStockToVerify: packingView.activeRows.filter(
        (row) => row.verification === null || row.needsReverification,
      ),
    };
  }

  async recordCutting(input: RecordCuttingInput): Promise<void> {
    const { error } = await this.supabase.rpc('record_cutting_transaction', {
      requested_source_lot_id: input.sourceLotId,
      requested_source_quantity: input.sourceQuantity,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
      requested_performed_by: input.performedBy,
      requested_cut_type: input.cutType,
      requested_outputs: input.outputs.map((output) => ({
        kind: output.kind,
        label: output.label,
        quantity: output.quantity,
        destination_location_id: output.destinationLocationId,
      })),
      requested_loss_quantity: input.lossQuantity,
      requested_loss_reason: input.lossReason,
      requested_notes: input.notes,
    });
    if (error) throw error;
  }

  async transfer(input: {
    lotId: string;
    quantity: number;
    destinationLocationId: string;
    reference: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('transfer_intermediate_stock', {
      requested_lot_id: input.lotId,
      requested_quantity: input.quantity,
      requested_destination_location_id: input.destinationLocationId,
      requested_occurred_at: new Date().toISOString(),
      requested_reference: input.reference,
    });
    if (error) throw error;
  }

  async recordRecoveredCream(input: {
    batchId: string;
    quantity: number;
    destinationLocationId: string;
    occurredAt: string;
    notes: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('record_recovered_coproduct', {
      requested_batch_id: input.batchId,
      requested_quantity: input.quantity,
      requested_destination_location_id: input.destinationLocationId,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
      requested_notes: input.notes,
    });
    if (error) throw error;
  }
}
