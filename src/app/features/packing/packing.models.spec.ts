import { describe, expect, it } from 'vitest';
import {
  expectedPackedWeightKg,
  fifoSourceId,
  packetEquivalent,
  type PackingSourceLot,
} from './packing.models';

describe('packing helpers', () => {
  it('keeps cases and loose packets while calculating packet equivalent', () => {
    expect(packetEquivalent(37, 6, 12)).toBe(450);
  });

  it('calculates expected packed weight from SKU weight', () => {
    expect(expectedPackedWeightKg(24, 400)).toBe(9.6);
  });

  it('orders FIFO by time, shift, then round', () => {
    const lots = [
      {
        id: 'round-2',
        produced_at: '2026-09-01T08:00:00Z',
        production_batches: { round_number: 2, production_shifts: { shift_number: 1 } },
      },
      {
        id: 'round-1',
        produced_at: '2026-09-01T08:00:00Z',
        production_batches: { round_number: 1, production_shifts: { shift_number: 1 } },
      },
    ] as PackingSourceLot[];
    expect(fifoSourceId(lots)).toBe('round-1');
  });
});
