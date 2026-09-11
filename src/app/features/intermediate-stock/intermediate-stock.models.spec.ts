import { describe, expect, it } from 'vitest';
import {
  fifoLotId,
  reconciledCuttingQuantity,
  type IntermediateLotSummary,
} from './intermediate-stock.models';

describe('intermediate stock helpers', () => {
  it('reconciles cutting outputs and loss', () => {
    expect(
      reconciledCuttingQuantity([{ quantity: 40 }, { quantity: 30 }, { quantity: 1.5 }], 0.5),
    ).toBe(72);
  });

  it('suggests the oldest eligible lot first', () => {
    const lots = [
      {
        id: 'newer',
        produced_at: '2026-09-03T10:00:00Z',
        current_quantity: 10,
        status: 'available',
      },
      {
        id: 'older',
        produced_at: '2026-09-01T10:00:00Z',
        current_quantity: 10,
        status: 'available',
      },
      {
        id: 'empty',
        produced_at: '2026-08-01T10:00:00Z',
        current_quantity: 0,
        status: 'depleted',
      },
    ] as IntermediateLotSummary[];
    expect(fifoLotId(lots)).toBe('older');
  });
});
