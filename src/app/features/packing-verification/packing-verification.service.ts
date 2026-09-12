import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  PackedRoundEntry,
  PackingVerification,
  PackingVerificationData,
  PackingVerificationSource,
  LooseStockConsolidationHistory,
  LooseStockPool,
  VerifyPackingInput,
} from './packing-verification.models';

@Injectable({ providedIn: 'root' })
export class PackingVerificationService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<PackingVerificationData> {
    const [entriesResult, verificationsResult, sourcesResult, poolsResult, historyResult] =
      await Promise.all([
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
        this.supabase
          .from('loose_stock_consolidation_pools')
          .select(
            'sku_id, sku_code, sku_description, packets_per_case, available_loose_packets, possible_cases, remainder_loose_packets, oldest_retained_at, pool_key',
          )
          .order('sku_code'),
        this.supabase
          .from('loose_stock_consolidation_history')
          .select(
            'id, consolidation_code, sku_id, sku_code, sku_description, packets_per_case_used, input_loose_packets, output_cases, consolidated_at, sent_to_distribution_at, consolidated_by_name, source_lot_codes',
          )
          .order('consolidated_at', { ascending: false }),
      ]);

    if (entriesResult.error) throw entriesResult.error;
    if (verificationsResult.error) throw verificationsResult.error;
    if (sourcesResult.error) throw sourcesResult.error;
    const optionalFeatureMissing = (code?: string) => code === '42P01' || code === 'PGRST205';
    if (poolsResult.error && !optionalFeatureMissing(poolsResult.error.code)) {
      throw poolsResult.error;
    }
    if (historyResult.error && !optionalFeatureMissing(historyResult.error.code)) {
      throw historyResult.error;
    }
    return {
      entries: entriesResult.data as unknown as PackedRoundEntry[],
      verifications: verificationsResult.data as unknown as PackingVerification[],
      sources: sourcesResult.data as unknown as PackingVerificationSource[],
      loosePools: (poolsResult.data ?? []) as unknown as LooseStockPool[],
      consolidations: (historyResult.data ?? []) as unknown as LooseStockConsolidationHistory[],
    };
  }

  async verify(input: VerifyPackingInput): Promise<void> {
    const { error } = await this.supabase.rpc('verify_production_sku_packing', {
      requested_sku_id: input.skuId,
      requested_corrected_cases: input.correctedCases,
      requested_corrected_loose_packets: input.correctedLoosePackets,
      requested_packets_per_case: input.packetsPerCase,
      requested_case_weight_kg: input.caseWeightKg,
      requested_source_round_uncertain: input.sourceRoundUncertain,
      requested_correction_reason: input.correctionReason.trim() || null,
    });
    if (error) throw error;
  }

  async sendToDistribution(
    verificationId: string,
    includeLoosePackets: boolean,
    exceptionReason: string,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('send_verified_sku_packing_to_distribution', {
      requested_verification_id: verificationId,
      requested_include_loose_packets: includeLoosePackets,
      requested_exception_reason: exceptionReason.trim() || null,
    });
    if (error) throw error;
  }

  async sendRetainedLooseToDistribution(
    verificationId: string,
    exceptionReason: string,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('send_retained_sku_loose_to_distribution', {
      requested_verification_id: verificationId,
      requested_exception_reason: exceptionReason.trim(),
    });
    if (error) throw error;
  }

  async consolidateLooseStock(
    skuId: string,
    packetsPerCase: number,
    caseQuantity: number,
  ): Promise<void> {
    const { error } = await this.supabase.rpc('consolidate_loose_stock_to_distribution', {
      requested_sku_id: skuId,
      requested_packets_per_case: packetsPerCase,
      requested_case_quantity: caseQuantity,
    });
    if (error) throw error;
  }
}
