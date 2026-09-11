import type { ProductionStatus } from '../production-board/production-board.models';

export interface DashboardMilkLot {
  id: string;
  lot_code: string;
  received_at: string;
  received_quantity: number;
  status: 'accepted' | 'closed';
  units_of_measure: { code: string } | null;
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
}

export interface LatestMilkDashboardData {
  milkLot: DashboardMilkLot | null;
  batches: DashboardProductionBatch[];
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
): MilkUsage {
  const received = Number(receivedQuantity);
  const used = batches.reduce(
    (total, batch) => total + Number(batch.actual_primary_input_quantity || 0),
    0,
  );
  const remaining = Math.max(0, received - used);
  const percentage = received > 0 ? Math.min(100, (used / received) * 100) : 0;
  return { received, used, remaining, percentage };
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
