export interface StorageLocationOption {
  id: string;
  code: string;
  name: string;
  location_type: string;
}

export interface IntermediateLotSummary {
  id: string;
  product_id: string;
  source_batch_id: string | null;
  source_transformation_id: string | null;
  parent_intermediate_lot_id: string | null;
  lot_code: string;
  display_label: string | null;
  produced_quantity: number;
  current_quantity: number;
  status: 'available' | 'reserved' | 'depleted' | 'quarantined';
  produced_at: string;
  products: {
    code: string;
    name: string;
    variant: string | null;
  } | null;
  units_of_measure: { code: string } | null;
  storage_locations: {
    id: string;
    code: string;
    name: string;
  } | null;
  production_batches: {
    batch_code: string;
    round_number: number;
    products: { variant: string | null } | null;
    source_lots: { lot_code: string } | null;
    production_shifts: { shift_number: number } | null;
  } | null;
}

export interface TransformationSummary {
  id: string;
  occurred_at: string;
  performed_by: string;
  cut_type: string | null;
  source_quantity: number;
  loss_quantity: number;
  loss_reason: string | null;
  notes: string | null;
  units_of_measure: { code: string } | null;
  production_batches: { batch_code: string } | null;
  transformation_outputs: Array<{
    id: string;
    output_kind: 'primary' | 'pan111' | 'coproduct';
    output_label: string;
    quantity: number;
    products: { code: string; name: string } | null;
    storage_locations: { name: string } | null;
  }>;
}

export interface ProductionBatchOption {
  id: string;
  batch_code: string;
  round_number: number;
  gross_output_quantity: number | null;
  status: string;
  products: { name: string; variant: string | null } | null;
  source_lots: { lot_code: string } | null;
  production_shifts: { shift_number: number } | null;
}

export interface IntermediateStockData {
  lots: IntermediateLotSummary[];
  locations: StorageLocationOption[];
  transformations: TransformationSummary[];
  productionBatches: ProductionBatchOption[];
}

export interface CuttingOutputInput {
  kind: 'primary' | 'pan111' | 'coproduct';
  label: string;
  quantity: number;
  destinationLocationId: string;
}

export interface RecordCuttingInput {
  sourceLotId: string;
  sourceQuantity: number;
  occurredAt: string;
  performedBy: string;
  cutType: string;
  outputs: CuttingOutputInput[];
  lossQuantity: number;
  lossReason: string | null;
  notes: string | null;
}

export function reconciledCuttingQuantity(
  outputs: Array<{ quantity: number | null }>,
  lossQuantity: number | null,
): number {
  return (
    outputs.reduce((total, output) => total + Number(output.quantity || 0), 0) +
    Number(lossQuantity || 0)
  );
}

export function fifoLotId(lots: IntermediateLotSummary[]): string | null {
  const eligible = lots
    .filter((lot) => lot.current_quantity > 0 && lot.status === 'available')
    .sort(
      (left, right) => new Date(left.produced_at).getTime() - new Date(right.produced_at).getTime(),
    );
  return eligible[0]?.id ?? null;
}
