export interface PackingSku {
  id: string;
  product_id: string;
  code: string;
  description: string;
  unit_weight_g: number | null;
  pieces_per_packet: number | null;
  products: { name: string; variant: string | null } | null;
  packaging_configs: Array<{
    packets_per_case: number | null;
    nominal_case_weight_kg: number | null;
    variable_case_allowed: boolean;
    effective_from: string;
    effective_to: string | null;
  }>;
}

export interface PackingSourceLot {
  id: string;
  product_id: string;
  lot_code: string;
  display_label: string | null;
  current_quantity: number;
  produced_at: string;
  source_transformation_id: string | null;
  products: { code: string; name: string; variant: string | null } | null;
  units_of_measure: { code: string } | null;
  storage_locations: { id: string; code: string; name: string } | null;
  production_batches: {
    batch_code: string;
    round_number: number;
    source_lots: { lot_code: string } | null;
    production_shifts: { shift_number: number } | null;
  } | null;
}

export interface PackingLocation {
  id: string;
  code: string;
  name: string;
}

export interface PackingRunSummary {
  id: string;
  completed_at: string;
  operator_team: string;
  cases_produced: number;
  loose_units_produced: number;
  packets_per_case_used: number | null;
  total_packet_equivalent: number;
  input_quantity_kg: number;
  actual_packed_weight_kg: number;
  yield_variance_kg: number;
  fifo_overridden: boolean;
  fifo_override_reason: string | null;
  skus: { code: string; description: string } | null;
  packing_run_sources: Array<{
    quantity_consumed: number;
    intermediate_lots: { lot_code: string } | null;
  }>;
}

export interface FinishedStockLot {
  id: string;
  lot_code: string;
  case_quantity: number;
  loose_unit_quantity: number;
  packet_equivalent: number;
  current_packet_quantity: number;
  packed_weight_kg: number;
  status: 'available' | 'reserved' | 'depleted' | 'quarantined';
  produced_at: string;
  skus: { code: string; description: string } | null;
  storage_locations: { name: string } | null;
}

export interface PackingData {
  skus: PackingSku[];
  sourceLots: PackingSourceLot[];
  locations: PackingLocation[];
  packingRuns: PackingRunSummary[];
  finishedLots: FinishedStockLot[];
}

export interface PackingSourceInput {
  intermediateLotId: string;
  quantity: number;
}

export interface CompletePackingInput {
  skuId: string;
  completedAt: string;
  operatorTeam: string;
  cases: number;
  looseUnits: number;
  packetsPerCaseOverride: number | null;
  actualPackedWeightKg: number | null;
  sources: PackingSourceInput[];
  fifoOverrideReason: string | null;
  weightVarianceReason: string | null;
  wrappersUsed: number | null;
  casesUsed: number | null;
  destinationLocationId: string;
  notes: string | null;
}

export function packetEquivalent(
  cases: number | null,
  loosePackets: number | null,
  packetsPerCase: number | null,
): number {
  return Number(cases || 0) * Number(packetsPerCase || 0) + Number(loosePackets || 0);
}

export function expectedPackedWeightKg(totalPackets: number, unitWeightG: number | null): number {
  return unitWeightG === null ? 0 : (totalPackets * Number(unitWeightG)) / 1000;
}

export function fifoSourceId(lots: PackingSourceLot[]): string | null {
  return (
    [...lots].sort(
      (left, right) =>
        new Date(left.produced_at).getTime() - new Date(right.produced_at).getTime() ||
        Number(left.production_batches?.production_shifts?.shift_number || 0) -
          Number(right.production_batches?.production_shifts?.shift_number || 0) ||
        Number(left.production_batches?.round_number || 0) -
          Number(right.production_batches?.round_number || 0),
    )[0]?.id ?? null
  );
}
