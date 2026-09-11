import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  RecipeVersionOption,
  SourceLotOption,
  TransformationHistory,
  TransformationInventoryBalance,
  TransformationLocation,
  TransformationLotOption,
  TransformationProduct,
  TransformationType,
  TransformationUnit,
} from './transformation.models';

export interface TransformationData {
  lots: TransformationLotOption[];
  sourceLots: SourceLotOption[];
  inventoryBalances: TransformationInventoryBalance[];
  products: TransformationProduct[];
  units: TransformationUnit[];
  locations: TransformationLocation[];
  recipeVersions: RecipeVersionOption[];
  history: TransformationHistory[];
}

export interface RecordTransformationInput {
  type: TransformationType;
  processTemplate: string;
  occurredAt: string;
  performedBy: string;
  recipeVersionId: string | null;
  intermediateInputs: Array<{
    intermediate_lot_id: string;
    quantity: number;
    standard_quantity: number | null;
  }>;
  sourceLotInputs: Array<{ source_lot_id: string; quantity: number }>;
  inventoryInputs: Array<{
    inventory_lot_id: string;
    source_location_id: string;
    quantity: number;
    standard_quantity: number | null;
  }>;
  outputs: Array<{
    product_id: string;
    quantity: number;
    uom_id: string;
    destination_location_id: string;
    kind: string;
    label: string;
  }>;
  controls: Array<{
    code: string;
    label: string;
    numeric_value: number | null;
    text_value: string | null;
    uom_label: string | null;
    target_value: number | null;
    min_value: number | null;
    max_value: number | null;
  }>;
  notes: string | null;
}

@Injectable({ providedIn: 'root' })
export class TransformationService {
  private readonly supabase = inject(SupabaseService).client;

  async load(): Promise<TransformationData> {
    const [
      lotsResult,
      sourceLotsResult,
      sourceBalancesResult,
      inventoryResult,
      productsResult,
      unitsResult,
      locationsResult,
      recipesResult,
      historyResult,
    ] = await Promise.all([
      this.supabase
        .from('intermediate_lots')
        .select(
          'id, product_id, lot_code, display_label, current_quantity, uom_id, produced_at, products(code, name), units_of_measure(code), storage_locations(name)',
        )
        .in('status', ['available', 'reserved'])
        .gt('current_quantity', 0)
        .order('produced_at'),
      this.supabase
        .from('source_lots')
        .select('id, lot_type, lot_code, received_quantity, uom_id, status, units_of_measure(code)')
        .neq('status', 'rejected')
        .order('received_at'),
      this.supabase.from('source_lot_available_balances').select('*'),
      this.supabase.from('inventory_balances').select('*').order('item_name'),
      this.supabase.from('products').select('id, code, name').eq('active', true).order('name'),
      this.supabase
        .from('units_of_measure')
        .select('id, code, name')
        .eq('active', true)
        .order('code'),
      this.supabase
        .from('storage_locations')
        .select('id, code, name')
        .eq('active', true)
        .order('name'),
      this.supabase
        .from('recipe_versions')
        .select('id, version_number, recipes(name, products(name))')
        .order('effective_from', { ascending: false }),
      this.supabase
        .from('transformations')
        .select(
          'id, transformation_type, process_template, occurred_at, performed_by, notes, recipe_versions(version_number, recipes(name)), transformation_inputs(quantity, standard_quantity, variance_quantity, intermediate_lots(lot_code, products(name), units_of_measure(code))), transformation_source_lot_inputs(quantity, source_lots(lot_code, lot_type), units_of_measure(code)), transformation_inventory_inputs(quantity, standard_quantity, variance_quantity, inventory_lots(lot_code, inventory_items(name)), units_of_measure(code)), transformation_outputs(output_kind, output_label, quantity, products(name), units_of_measure(code), intermediate_lots:intermediate_lots!transformation_outputs_generated_intermediate_lot_id_fkey(lot_code)), transformation_process_controls(control_label, numeric_value, text_value, uom_label, in_spec)',
        )
        .eq('status', 'completed')
        .not('process_template', 'is', null)
        .order('occurred_at', { ascending: false })
        .limit(30),
    ]);

    for (const result of [
      lotsResult,
      sourceLotsResult,
      sourceBalancesResult,
      inventoryResult,
      productsResult,
      unitsResult,
      locationsResult,
      recipesResult,
      historyResult,
    ]) {
      if (result.error) throw result.error;
    }

    const sourceBalances = new Map(
      (sourceBalancesResult.data ?? []).map((row) => [
        row.source_lot_id,
        Number(row.available_quantity),
      ]),
    );

    return {
      lots: lotsResult.data as unknown as TransformationLotOption[],
      sourceLots: (sourceLotsResult.data ?? [])
        .map((lot) => ({
          ...lot,
          received_quantity: Number(lot.received_quantity),
          available_quantity: sourceBalances.get(lot.id) ?? 0,
        }))
        .filter((lot) => lot.available_quantity > 0) as unknown as SourceLotOption[],
      inventoryBalances: (inventoryResult.data ?? []).filter(
        (balance) => Number(balance.current_quantity) > 0,
      ) as unknown as TransformationInventoryBalance[],
      products: productsResult.data as unknown as TransformationProduct[],
      units: unitsResult.data as unknown as TransformationUnit[],
      locations: locationsResult.data as unknown as TransformationLocation[],
      recipeVersions: recipesResult.data as unknown as RecipeVersionOption[],
      history: historyResult.data as unknown as TransformationHistory[],
    };
  }

  async record(input: RecordTransformationInput): Promise<string> {
    const { data, error } = await this.supabase.rpc('record_process_transformation', {
      requested_transformation_type: input.type,
      requested_process_template: input.processTemplate,
      requested_occurred_at: new Date(input.occurredAt).toISOString(),
      requested_performed_by: input.performedBy,
      requested_recipe_version_id: input.recipeVersionId,
      requested_intermediate_inputs: input.intermediateInputs,
      requested_source_lot_inputs: input.sourceLotInputs,
      requested_inventory_inputs: input.inventoryInputs,
      requested_outputs: input.outputs,
      requested_controls: input.controls,
      requested_notes: input.notes,
    });
    if (error) throw error;
    return data as string;
  }
}
