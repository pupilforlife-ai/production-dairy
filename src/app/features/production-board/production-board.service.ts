import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import {
  type BoardData,
  type BoardSku,
  type PaneerCutFormat,
  type PaneerProcessStage,
  type PressedPaneerBlock,
  type ProductOption,
  type ProductionHandlingEvent,
  type ProductionBatchSummary,
  type ProductionCreamBucket,
  type ProductionIngredientIssue,
  type RoundPackingEntry,
  type ShiftSummary,
  type SourceLotOption,
} from './production-board.models';

export type EditableRoundField =
  'milk_quantity' | 'type' | 'milk_temperature' | 'process_stage' | 'cut_by' | 'cut_format';

@Injectable({ providedIn: 'root' })
export class ProductionBoardService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<BoardData> {
    const [
      lotsResult,
      productsResult,
      shiftsResult,
      batchesResult,
      skusResult,
      packingResult,
      blocksResult,
      handlingEventsResult,
      creamBucketsResult,
      ingredientIssuesResult,
    ] = await Promise.all([
      this.supabase
        .from('source_lots')
        .select('id, lot_code, received_at, received_quantity, uom_id, units_of_measure(code)')
        .eq('lot_type', 'milk')
        .eq('status', 'accepted')
        .order('received_at', { ascending: false }),
      this.supabase
        .from('products')
        .select('id, code, name, variant')
        .in('code', ['MALAI_PANEER', 'ROZANA_PANEER', 'RAW_HALLOUMI'])
        .eq('active', true)
        .order('name'),
      this.supabase
        .from('production_shifts')
        .select(
          'id, source_lot_id, shift_number, started_at, ended_at, status, team_notes, source_lots(lot_code, received_at), shift_members(person_name)',
        )
        .order('started_at', { ascending: false }),
      this.supabase
        .from('production_batches')
        .select(
          'id, batch_code, parent_source_lot_id, shift_id, round_number, product_id, recipe_version_id, planned_input_quantity, actual_primary_input_quantity, gross_output_quantity, pressed_block_count, milk_start_temperature_c, process_stage, process_stage_changed_at, cut_by, cut_format, cut_completed_at, cutting_allocation, status, started_at, completed_at, notes, locked_at, source_lots(lot_code), products(id, code, name, variant), production_shifts(shift_number, shift_members(person_name)), input_uom:units_of_measure!production_batches_input_uom_id_fkey(code), output_uom:units_of_measure!production_batches_output_uom_id_fkey(code), production_batch_stage_events(id, stage, changed_at)',
        )
        .order('created_at', { ascending: false }),
      this.supabase
        .from('skus')
        .select('id, product_id, code, description, packaging_configs(packets_per_case)')
        .eq('active', true)
        .order('code'),
      this.supabase
        .from('production_round_packing_entries')
        .select(
          'id, production_batch_id, sku_id, cases, loose_packets, recorded_at, skus(code, description)',
        )
        .order('recorded_at', { ascending: true }),
      this.supabase
        .from('production_round_blocks')
        .select('id, production_batch_id, block_number, weight_kg, updated_at')
        .order('block_number', { ascending: true }),
      this.supabase
        .from('production_round_handling_events')
        .select('id, production_batch_id, event_type, recorded_at, profiles(display_name)')
        .order('recorded_at', { ascending: false }),
      this.supabase
        .from('production_round_cream_buckets')
        .select(
          'id, production_batch_id, bucket_number, weight_kg, recorded_at, intermediate_lots(lot_code, storage_locations(name)), profiles(display_name)',
        )
        .order('bucket_number', { ascending: true }),
      this.supabase
        .from('production_round_ingredient_issues')
        .select(
          'id, production_batch_id, addition_stage, required_quantity, issued_quantity, shortage_quantity, last_attempted_at, units_of_measure(code), recipe_components(ingredients(name))',
        )
        .order('addition_stage'),
    ]);

    for (const result of [
      lotsResult,
      productsResult,
      shiftsResult,
      batchesResult,
      skusResult,
      packingResult,
      blocksResult,
      handlingEventsResult,
      creamBucketsResult,
      ingredientIssuesResult,
    ]) {
      if (result.error) throw result.error;
    }

    const batches = batchesResult.data as unknown as ProductionBatchSummary[];
    for (const batch of batches) {
      batch.production_batch_stage_events.sort(
        (left, right) => new Date(right.changed_at).getTime() - new Date(left.changed_at).getTime(),
      );
    }

    return {
      sourceLots: lotsResult.data as unknown as SourceLotOption[],
      products: productsResult.data as unknown as ProductOption[],
      shifts: shiftsResult.data as unknown as ShiftSummary[],
      batches,
      skus: skusResult.data as unknown as BoardSku[],
      packingEntries: packingResult.data as unknown as RoundPackingEntry[],
      blocks: blocksResult.data as unknown as PressedPaneerBlock[],
      handlingEvents: handlingEventsResult.data as unknown as ProductionHandlingEvent[],
      creamBuckets: creamBucketsResult.data as unknown as ProductionCreamBucket[],
      ingredientIssues: ingredientIssuesResult.data as unknown as ProductionIngredientIssue[],
    };
  }

  async createShift(input: {
    sourceLotId: string;
    shiftNumber: number;
    startedAt: string;
    teamMembers: string[];
    teamNotes: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('create_production_shift', {
      requested_source_lot_id: input.sourceLotId,
      requested_shift_number: input.shiftNumber,
      requested_started_at: new Date(input.startedAt).toISOString(),
      requested_team_members: input.teamMembers,
      requested_team_notes: input.teamNotes,
    });
    if (error) throw error;
  }

  async addRound(shiftId: string): Promise<void> {
    const { error } = await this.supabase.rpc('add_live_production_round', {
      requested_shift_id: shiftId,
    });
    if (error) throw error;
  }

  async addHalloumiRound(shiftId: string): Promise<void> {
    const { error } = await this.supabase.rpc('add_halloumi_production_round', {
      requested_shift_id: shiftId,
    });
    if (error) throw error;
  }

  async cancelAccidentalRound(batchId: string, reason: string): Promise<void> {
    const { error } = await this.supabase.rpc('cancel_accidental_production_round', {
      requested_batch_id: batchId,
      requested_reason: reason,
    });
    if (error) throw error;
  }

  async updateCell(
    batchId: string,
    field: EditableRoundField,
    value: string | number | PaneerProcessStage | PaneerCutFormat | null,
  ): Promise<Partial<ProductionBatchSummary>> {
    if (field === 'milk_quantity') {
      const { data, error } = await this.supabase.rpc('update_production_round_milk_quantity', {
        requested_batch_id: batchId,
        requested_quantity: Number(value),
      });
      if (error) throw error;
      return data as Partial<ProductionBatchSummary>;
    }

    const { data, error } = await this.supabase.rpc('update_live_production_round_cell', {
      requested_batch_id: batchId,
      requested_field: field,
      requested_value: value === null ? '' : String(value),
    });
    if (error) throw error;
    return data as Partial<ProductionBatchSummary>;
  }

  async verifySppCut(batchId: string, verifiedSppWeightKg: number): Promise<void> {
    const { error } = await this.supabase.rpc('verify_production_round_spp_cut', {
      requested_batch_id: batchId,
      requested_spp_weight_kg: verifiedSppWeightKg,
      requested_occurred_at: new Date().toISOString(),
      requested_notes: null,
    });
    if (error) throw error;
  }

  async addPackingEntry(
    batchId: string,
    skuId: string,
    cases: number,
    loosePackets: number,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('add_production_round_packing_entry', {
      requested_batch_id: batchId,
      requested_sku_id: skuId,
      requested_cases: cases,
      requested_loose_packets: loosePackets,
    });
    if (error) throw error;
  }

  async correctPackingEntry(
    entryId: string,
    skuId: string,
    cases: number,
    loosePackets: number,
    reason: string,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('correct_production_round_packing_entry', {
      requested_entry_id: entryId,
      requested_sku_id: skuId,
      requested_cases: cases,
      requested_loose_packets: loosePackets,
      requested_reason: reason,
    });
    if (error) throw error;
  }

  async setBlockCount(batchId: string, blockCount: number): Promise<void> {
    const { error } = await this.supabase.rpc('set_production_round_block_count', {
      requested_batch_id: batchId,
      requested_block_count: blockCount,
    });
    if (error) throw error;
  }

  async setBlockWeight(
    batchId: string,
    blockNumber: number,
    weightKg: number,
  ): Promise<PressedPaneerBlock> {
    const { data, error } = await this.supabase.rpc('set_production_round_block_weight', {
      requested_batch_id: batchId,
      requested_block_number: blockNumber,
      requested_weight_kg: weightKg,
    });
    if (error) throw error;
    return data as PressedPaneerBlock;
  }

  async addCreamBucket(batchId: string, weightKg: number): Promise<void> {
    const { error } = await this.supabase.rpc('add_production_round_cream_bucket', {
      requested_batch_id: batchId,
      requested_weight_kg: weightKg,
    });
    if (error) throw error;
  }

  async updateCreamBucketWeight(bucketId: string, weightKg: number): Promise<void> {
    const { error } = await this.supabase.rpc('update_production_round_cream_bucket_weight', {
      requested_bucket_id: bucketId,
      requested_weight_kg: weightKg,
    });
    if (error) throw error;
  }

  async voidCreamBucket(bucketId: string, reason: string): Promise<void> {
    const { error } = await this.supabase.rpc('void_production_round_cream_bucket', {
      requested_bucket_id: bucketId,
      requested_reason: reason,
    });
    if (error) throw error;
  }

  async recordHalloumiOutput(batchId: string, weightKg: number): Promise<void> {
    const { error } = await this.supabase.rpc('record_halloumi_raw_output', {
      requested_batch_id: batchId,
      requested_weight_kg: weightKg,
    });
    if (error) throw error;
  }

  async retryIngredientShortages(batchId: string): Promise<void> {
    const { error } = await this.supabase.rpc('retry_production_round_ingredient_shortages', {
      requested_batch_id: batchId,
    });
    if (error) throw error;
  }
}
