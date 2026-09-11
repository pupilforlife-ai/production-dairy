import { describe, expect, it } from 'vitest';
import {
  calculateMilkUsage,
  groupRoundsByShift,
  type DashboardProductionBatch,
} from './dashboard.models';

const batches = [
  {
    id: 'round-2',
    round_number: 2,
    actual_primary_input_quantity: 500,
    gross_output_quantity: 71,
    status: 'pressing',
    production_shifts: {
      id: 'shift-1',
      shift_number: 1,
      started_at: '2026-09-05T06:00:00Z',
      shift_members: [{ person_name: 'Asha' }],
    },
  },
  {
    id: 'round-1',
    round_number: 1,
    actual_primary_input_quantity: 480,
    gross_output_quantity: 68,
    status: 'cut',
    production_shifts: {
      id: 'shift-1',
      shift_number: 1,
      started_at: '2026-09-05T06:00:00Z',
      shift_members: [{ person_name: 'Asha' }],
    },
  },
] as DashboardProductionBatch[];

describe('factory dashboard helpers', () => {
  it('calculates latest milk usage', () => {
    expect(calculateMilkUsage(2000, batches)).toEqual({
      received: 2000,
      used: 980,
      remaining: 1020,
      percentage: 49,
    });
  });

  it('groups rounds by shift and orders rounds', () => {
    const summaries = groupRoundsByShift(batches);
    expect(summaries).toHaveLength(1);
    expect(summaries[0]?.milkUsed).toBe(980);
    expect(summaries[0]?.grossOutput).toBe(139);
    expect(summaries[0]?.rounds.map((round) => round.round_number)).toEqual([1, 2]);
  });
});
