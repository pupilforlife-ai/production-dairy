import type { ProductionStatus } from '../production-board/production-board.models';

export interface DashboardMilkLot {
  id: string;
  lot_code: string;
  received_at: string;
  received_quantity: number;
  status: 'accepted' | 'closed';
  units_of_measure: { code: string } | null;
  source_lot_milk_sales: { quantity: number }[];
}

export interface DashboardProductionBatch {
  id: string;
  round_number: number;
  actual_primary_input_quantity: number | null;
  gross_output_quantity: number | null;
  status: ProductionStatus;
  products: { name: string; variant: string | null } | null;
  production_shifts: {
    id: string;
    shift_number: number;
    started_at: string;
    shift_members: { person_name: string }[];
  } | null;
  production_round_packing_entries: {
    cases: number;
    loose_packets: number;
    skus: {
      code: string;
      description: string;
      unit_weight_g: number | null;
      products: { name: string; variant: string | null } | null;
      packaging_configs: {
        packets_per_case: number | null;
        nominal_case_weight_kg: number | null;
      }[];
    } | null;
  }[];
  production_round_blocks: { weight_kg: number | null }[];
}

export interface DashboardFinishedStockLot {
  id: string;
  packed_weight_kg: number;
  current_packet_quantity: number;
  status: 'available' | 'reserved' | 'depleted' | 'quarantined';
  skus: {
    code: string;
    description: string;
    products: { name: string; variant: string | null } | null;
  } | null;
}

export interface DashboardPackingVerification {
  id: string;
  corrected_cases: number;
  corrected_loose_packets: number;
  packets_per_case_used: number | null;
  case_weight_kg_used: number | null;
  distributed_cases: number;
  distributed_loose_packets: number;
  rejected_cases: number;
  rejected_loose_packets: number;
  status: string;
  skus: {
    code: string;
    description: string;
    unit_weight_g: number | null;
    products: { name: string; variant: string | null } | null;
    packaging_configs: { packets_per_case: number | null; nominal_case_weight_kg: number | null }[];
  } | null;
}

export interface LatestMilkDashboardData {
  milkLot: DashboardMilkLot | null;
  batches: DashboardProductionBatch[];
  finishedLots: DashboardFinishedStockLot[];
  packingVerifications: DashboardPackingVerification[];
}

export interface MilkUsage {
  received: number;
  used: number;
  remaining: number;
  percentage: number;
}

export interface ShiftRoundSummary {
  id: string;
  shiftNumber: number;
  startedAt: string;
  team: string[];
  milkUsed: number;
  grossOutput: number;
  rounds: DashboardProductionBatch[];
}

export function calculateMilkUsage(
  receivedQuantity: number,
  batches: DashboardProductionBatch[],
  milkSales: { quantity: number }[] = [],
): MilkUsage {
  const received = Number(receivedQuantity);
  const used = batches.reduce(
    (total, batch) => total + Number(batch.actual_primary_input_quantity || 0),
    0,
  );
  const sold = milkSales.reduce((total, sale) => total + Number(sale.quantity || 0), 0);
  const allocated = used + sold;
  const remaining = Math.max(0, received - allocated);
  const percentage = received > 0 ? Math.min(100, (allocated / received) * 100) : 0;
  return { received, used: allocated, remaining, percentage };
}

export function groupRoundsByShift(batches: DashboardProductionBatch[]): ShiftRoundSummary[] {
  const shifts = new Map<string, ShiftRoundSummary>();
  for (const batch of batches) {
    const shift = batch.production_shifts;
    if (!shift) continue;
    const summary = shifts.get(shift.id) ?? {
      id: shift.id,
      shiftNumber: shift.shift_number,
      startedAt: shift.started_at,
      team: shift.shift_members.map((member) => member.person_name),
      milkUsed: 0,
      grossOutput: 0,
      rounds: [],
    };
    summary.rounds.push(batch);
    summary.milkUsed += Number(batch.actual_primary_input_quantity || 0);
    summary.grossOutput += Number(batch.gross_output_quantity || 0);
    shifts.set(shift.id, summary);
  }

  return [...shifts.values()]
    .map((shift) => ({
      ...shift,
      rounds: [...shift.rounds].sort((left, right) => left.round_number - right.round_number),
    }))
    .sort((left, right) => left.shiftNumber - right.shiftNumber);
}
