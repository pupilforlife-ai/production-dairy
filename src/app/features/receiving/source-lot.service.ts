import { Injectable, inject, signal } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  CreateSourceLotInput,
  SourceLotProductionBatch,
  SourceLotSummary,
  UpdateSourceLotInput,
} from './source-lot.models';

@Injectable({ providedIn: 'root' })
export class SourceLotService {
  private readonly supabase = inject(SupabaseService).client;
  readonly closeFeatureAvailable = signal(false);
  readonly milkSalesFeatureAvailable = signal(false);

  async listRecent(): Promise<SourceLotSummary[]> {
    const { data: lotData, error: lotError } = await this.supabase
      .from('source_lots')
      .select(
        'id, lot_type, lot_code, invoice_number, received_from, received_at, received_quantity, status, notes, locked_at, units_of_measure(code), suppliers(name), source_lot_allocations(quantity)',
      )
      .order('received_at', { ascending: false })
      .limit(50);
    if (lotError) throw lotError;
    if (!lotData?.length) return [];

    const closureResult = await this.supabase
      .from('source_lots')
      .select('id, unaccounted_loss_quantity, closure_notes')
      .in(
        'id',
        lotData.map((lot) => lot.id),
      );
    const missingClosureColumns =
      closureResult.error?.code === '42703' || closureResult.error?.code === 'PGRST204';
    if (closureResult.error && !missingClosureColumns) throw closureResult.error;
    this.closeFeatureAvailable.set(!closureResult.error);

    const closureByLot = new Map(
      (closureResult.data ?? []).map((row) => [
        row.id,
        {
          unaccounted_loss_quantity: row.unaccounted_loss_quantity,
          closure_notes: row.closure_notes,
        },
      ]),
    );

    const salesResult = await this.supabase
      .from('source_lot_milk_sales')
      .select('id, source_lot_id, sale_date, customer, quantity')
      .in(
        'source_lot_id',
        lotData.map((lot) => lot.id),
      )
      .order('sale_date', { ascending: false });
    const missingSalesTable =
      salesResult.error?.code === '42P01' || salesResult.error?.code === 'PGRST205';
    if (salesResult.error && !missingSalesTable) throw salesResult.error;
    this.milkSalesFeatureAvailable.set(!salesResult.error);

    const salesByLot = new Map<string, NonNullable<typeof salesResult.data>>();
    for (const sale of salesResult.data ?? []) {
      salesByLot.set(sale.source_lot_id, [...(salesByLot.get(sale.source_lot_id) ?? []), sale]);
    }

    const { data: batchData, error: batchError } = await this.supabase
      .from('production_batches')
      .select(
        'id, parent_source_lot_id, actual_primary_input_quantity, gross_output_quantity, cut_format, status, products(variant), production_round_blocks(weight_kg), production_round_cream_buckets(weight_kg), production_round_packing_entries(cases, loose_packets, skus(code)), transformations!transformations_source_batch_id_fkey(source_quantity, cut_type, transformation_outputs(quantity, output_label, products(code)))',
      )
      .in(
        'parent_source_lot_id',
        lotData.map((lot) => lot.id),
      );
    if (batchError) throw batchError;

    const batchesByLot = new Map<string, SourceLotProductionBatch[]>();
    for (const batch of (batchData ?? []) as unknown as SourceLotProductionBatch[]) {
      batchesByLot.set(batch.parent_source_lot_id, [
        ...(batchesByLot.get(batch.parent_source_lot_id) ?? []),
        batch,
      ]);
    }

    return lotData.map(
      (lot) =>
        ({
          ...lot,
          ...(closureByLot.get(lot.id) ?? {
            unaccounted_loss_quantity: null,
            closure_notes: null,
          }),
          source_lot_milk_sales: salesByLot.get(lot.id) ?? [],
          production_batches: batchesByLot.get(lot.id) ?? [],
        }) as unknown as SourceLotSummary,
    );
  }

  async create(input: CreateSourceLotInput): Promise<void> {
    const { data: unit, error: unitError } = await this.supabase
      .from('units_of_measure')
      .select('id')
      .eq('code', 'L')
      .single<{ id: string }>();
    if (unitError) throw unitError;

    const { error } = await this.supabase.from('source_lots').insert({
      lot_type: input.lotType,
      lot_code: input.lotCode.trim(),
      invoice_number: input.invoiceNumber.trim(),
      received_from: input.receivedFrom.trim(),
      received_at: new Date(input.receivedAt).toISOString(),
      received_quantity: input.receivedQuantity,
      uom_id: unit.id,
      status: input.status,
      notes: input.notes?.trim() || null,
    });
    if (error) throw error;
  }

  async update(input: UpdateSourceLotInput): Promise<void> {
    const { error } = await this.supabase.rpc('update_source_lot_receipt', {
      requested_source_lot_id: input.id,
      requested_lot_type: input.lotType,
      requested_lot_code: input.lotCode,
      requested_invoice_number: input.invoiceNumber,
      requested_received_from: input.receivedFrom,
      requested_received_at: new Date(input.receivedAt).toISOString(),
      requested_received_quantity: input.receivedQuantity,
      requested_status: input.status,
      requested_notes: input.notes,
    });
    if (error) throw error;
  }

  async closeMilkProduction(sourceLotId: string, closureNotes: string | null): Promise<number> {
    const { data, error } = await this.supabase.rpc('close_milk_production', {
      requested_source_lot_id: sourceLotId,
      requested_closure_notes: closureNotes,
    });
    if (error) throw error;
    return Number(data ?? 0);
  }

  async recordMilkSale(input: {
    sourceLotId: string;
    saleDate: string;
    customer: string;
    quantity: number;
  }): Promise<void> {
    const { error } = await this.supabase.rpc('record_source_lot_milk_sale', {
      requested_source_lot_id: input.sourceLotId,
      requested_sale_date: input.saleDate,
      requested_customer: input.customer,
      requested_quantity: input.quantity,
    });
    if (error) throw error;
  }
}
