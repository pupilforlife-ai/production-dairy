import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  InventoryBalance,
  InventoryData,
  InventoryItem,
  InventoryItemType,
  InventoryLocation,
  InventoryMovementSummary,
  InventoryReference,
  InventoryUsageSummary,
  InventoryUnit,
} from './inventory.models';

@Injectable({ providedIn: 'root' })
export class InventoryService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<InventoryData> {
    const [
      itemsResult,
      balancesResult,
      locationsResult,
      unitsResult,
      batchesResult,
      packingResult,
      movementsResult,
      usageSummaryResult,
    ] = await Promise.all([
      this.supabase
        .from('inventory_items')
        .select('id, item_type, code, name, default_uom_id, active, units_of_measure(code)')
        .eq('active', true)
        .order('name'),
      this.supabase.from('inventory_balances').select('*').order('item_name'),
      this.supabase
        .from('storage_locations')
        .select('id, code, name')
        .eq('active', true)
        .in('code', ['BULK_INGREDIENT', 'INTERMEDIATE_INGREDIENT', 'PRODUCTION'])
        .order('name'),
      this.supabase
        .from('units_of_measure')
        .select('id, code, name')
        .eq('active', true)
        .order('code'),
      this.supabase
        .from('production_batches')
        .select('id, batch_code')
        .neq('status', 'cancelled')
        .order('created_at', { ascending: false })
        .limit(100),
      this.supabase
        .from('packing_runs')
        .select('id, completed_at, skus(code)')
        .eq('status', 'completed')
        .order('completed_at', { ascending: false })
        .limit(100),
      this.supabase
        .from('inventory_movements')
        .select(
          'id, movement_type, quantity, reason, notes, occurred_at, inventory_items(code, name, item_type), inventory_lots(lot_code), units_of_measure(code), source_location:storage_locations!inventory_movements_source_location_id_fkey(name), destination_location:storage_locations!inventory_movements_destination_location_id_fkey(name), production_batches(batch_code), packing_runs(id, skus(code))',
        )
        .order('occurred_at', { ascending: false })
        .limit(100),
      this.supabase
        .from('inventory_usage_by_milk_lot')
        .select('*')
        .order('last_used_at', { ascending: false })
        .limit(200),
    ]);

    for (const result of [
      itemsResult,
      balancesResult,
      locationsResult,
      unitsResult,
      batchesResult,
      packingResult,
      movementsResult,
    ]) {
      if (result.error) throw result.error;
    }
    if (
      usageSummaryResult.error &&
      !['42P01', 'PGRST205'].includes(usageSummaryResult.error.code ?? '')
    ) {
      throw usageSummaryResult.error;
    }

    return {
      items: itemsResult.data as unknown as InventoryItem[],
      balances: balancesResult.data as unknown as InventoryBalance[],
      locations: locationsResult.data as unknown as InventoryLocation[],
      units: unitsResult.data as unknown as InventoryUnit[],
      productionReferences: (batchesResult.data ?? []).map((batch) => ({
        id: batch.id,
        label: batch.batch_code,
      })) as InventoryReference[],
      packingReferences: (packingResult.data ?? []).map((run) => ({
        id: run.id,
        label:
          (run.skus as unknown as { code: string } | null)?.code +
          ' · ' +
          new Date(run.completed_at).toLocaleDateString(),
      })) as InventoryReference[],
      movements: movementsResult.data as unknown as InventoryMovementSummary[],
      usageSummaries: (usageSummaryResult.data ?? []) as unknown as InventoryUsageSummary[],
    };
  }

  async createItem(input: {
    itemType: InventoryItemType;
    code: string;
    name: string;
    uomId: string;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('create_inventory_item', {
      requested_item_type: input.itemType,
      requested_code: input.code,
      requested_name: input.name,
      requested_uom_id: input.uomId,
    });
    if (error) throw error;
  }

  async receive(input: {
    itemId: string;
    lotCode: string;
    quantity: number;
    destinationLocationId: string;
    receivedAt: string;
    expiryDate: string | null;
    notes: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('receive_inventory', {
      requested_item_id: input.itemId,
      requested_lot_code: input.lotCode,
      requested_quantity: input.quantity,
      requested_destination_location_id: input.destinationLocationId,
      requested_received_at: new Date(input.receivedAt).toISOString(),
      requested_expiry_date: input.expiryDate,
      requested_notes: input.notes,
    });
    if (error) throw error;
  }

  async transfer(input: {
    lotId: string;
    sourceLocationId: string;
    destinationLocationId: string;
    quantity: number;
    occurredAt: string;
    notes: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('transfer_inventory', {
      requested_lot_id: input.lotId,
      requested_source_location_id: input.sourceLocationId,
      requested_destination_location_id: input.destinationLocationId,
      requested_quantity: input.quantity,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
      requested_notes: input.notes,
    });
    if (error) throw error;
  }

  async consume(input: {
    lotId: string;
    sourceLocationId: string;
    quantity: number;
    productionBatchId: string | null;
    packingRunId: string | null;
    occurredAt: string;
    notes: string | null;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('consume_inventory', {
      requested_lot_id: input.lotId,
      requested_source_location_id: input.sourceLocationId,
      requested_quantity: input.quantity,
      requested_production_batch_id: input.productionBatchId,
      requested_packing_run_id: input.packingRunId,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
      requested_notes: input.notes,
    });
    if (error) throw error;
  }

  async adjust(input: {
    lotId: string;
    locationId: string;
    adjustmentQuantity: number;
    reason: string;
    occurredAt: string;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('adjust_inventory_stocktake', {
      requested_lot_id: input.lotId,
      requested_location_id: input.locationId,
      requested_adjustment_quantity: input.adjustmentQuantity,
      requested_reason: input.reason,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
    });
    if (error) throw error;
  }
}
