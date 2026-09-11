import { describe, expect, it } from 'vitest';
import {
  allocatedQuantity,
  milkSoldQuantity,
  productionQuantity,
  remainingQuantity,
  summarizeMilkLotProduction,
  type SourceLotProductionBatch,
} from './source-lot.models';

function batch(
  quantity: number,
  status: string,
  overrides: Partial<SourceLotProductionBatch> = {},
): SourceLotProductionBatch {
  return {
    id: `batch-${quantity}-${status}`,
    parent_source_lot_id: 'lot-id',
    actual_primary_input_quantity: quantity,
    gross_output_quantity: null,
    cut_format: null,
    status,
    products: { variant: 'D' },
    production_round_blocks: [],
    production_round_cream_buckets: [],
    production_round_packing_entries: [],
    transformations: [],
    ...overrides,
  };
}

describe('source lot balances', () => {
  it('totals vessel allocations', () => {
    expect(allocatedQuantity([{ quantity: 10_000 }, { quantity: 3_000 }])).toBe(13_000);
  });

  it('calculates the unallocated receipt balance', () => {
    expect(
      remainingQuantity({
        id: 'lot-id',
        lot_type: 'milk',
        lot_code: '030926',
        invoice_number: null,
        received_from: null,
        received_at: '2026-09-03T00:00:00Z',
        received_quantity: 25_000,
        status: 'accepted',
        notes: null,
        locked_at: null,
        unaccounted_loss_quantity: null,
        closure_notes: null,
        units_of_measure: { code: 'L' },
        suppliers: null,
        source_lot_allocations: [{ quantity: 10_000 }, { quantity: 3_000 }],
        source_lot_milk_sales: [],
        production_batches: [batch(500, 'in_production'), batch(500, 'cancelled')],
      }),
    ).toBe(12_000);
  });

  it('uses production consumption when it exceeds storage allocation', () => {
    expect(
      productionQuantity([
        batch(500, 'in_production'),
        batch(450, 'ready_for_cutting'),
        batch(500, 'cancelled'),
      ]),
    ).toBe(950);

    expect(
      remainingQuantity({
        id: 'lot-id',
        lot_type: 'milk',
        lot_code: '070926',
        invoice_number: null,
        received_from: null,
        received_at: '2026-09-07T00:00:00Z',
        received_quantity: 2_000,
        status: 'accepted',
        notes: null,
        locked_at: null,
        unaccounted_loss_quantity: null,
        closure_notes: null,
        units_of_measure: { code: 'L' },
        suppliers: null,
        source_lot_allocations: [{ quantity: 500 }],
        source_lot_milk_sales: [],
        production_batches: [batch(500, 'in_production'), batch(450, 'ready_for_cutting')],
      }),
    ).toBe(1_050);
  });

  it('shows no available balance after remaining milk is closed as process loss', () => {
    expect(
      remainingQuantity({
        id: 'closed-lot-id',
        lot_type: 'milk',
        lot_code: '080926',
        invoice_number: null,
        received_from: null,
        received_at: '2026-09-08T00:00:00Z',
        received_quantity: 2_000,
        status: 'closed',
        notes: null,
        locked_at: '2026-09-10T10:00:00Z',
        unaccounted_loss_quantity: 50,
        closure_notes: 'Normal process loss and spillage',
        units_of_measure: { code: 'L' },
        suppliers: null,
        source_lot_allocations: [],
        source_lot_milk_sales: [],
        production_batches: [batch(1_950, 'ready_for_cutting')],
      }),
    ).toBe(0);
  });

  it('deducts owner-recorded milk sales from the available milk balance', () => {
    const sales = [
      {
        id: 'sale-1',
        source_lot_id: 'lot-id',
        sale_date: '2026-09-10',
        customer: 'Customer A',
        quantity: 200,
      },
      {
        id: 'sale-2',
        source_lot_id: 'lot-id',
        sale_date: '2026-09-10',
        customer: 'Customer B',
        quantity: 50,
      },
    ];

    expect(milkSoldQuantity(sales)).toBe(250);
    expect(
      remainingQuantity({
        id: 'lot-id',
        lot_type: 'milk',
        lot_code: '100926',
        invoice_number: null,
        received_from: null,
        received_at: '2026-09-10T00:00:00Z',
        received_quantity: 2_000,
        status: 'accepted',
        notes: null,
        locked_at: null,
        unaccounted_loss_quantity: null,
        closure_notes: null,
        units_of_measure: { code: 'L' },
        suppliers: null,
        source_lot_allocations: [],
        source_lot_milk_sales: sales,
        production_batches: [batch(1_000, 'ready_for_cutting')],
      }),
    ).toBe(750);
  });

  it('summarises yield, rounds, cream, SKUs, PAN111, and SPP by milk receipt', () => {
    const lot = {
      id: 'lot-id',
      lot_type: 'milk' as const,
      lot_code: '100926',
      invoice_number: 'INV-1',
      received_from: 'Farm',
      received_at: '2026-09-10T06:00:00Z',
      received_quantity: 2_000,
      status: 'accepted' as const,
      notes: null,
      locked_at: null,
      unaccounted_loss_quantity: null,
      closure_notes: null,
      units_of_measure: { code: 'L' },
      suppliers: null,
      source_lot_allocations: [],
      source_lot_milk_sales: [],
      production_batches: [
        batch(500, 'ready_for_cutting', {
          products: { variant: 'C/S' },
          production_round_blocks: [{ weight_kg: 40 }, { weight_kg: 35 }],
          production_round_cream_buckets: [{ weight_kg: 8 }, { weight_kg: 7.5 }],
          production_round_packing_entries: [
            { cases: 4, loose_packets: 2, skus: { code: 'MPAN400' } },
          ],
          transformations: [
            {
              source_quantity: 75,
              cut_type: 'SPP pieces',
              transformation_outputs: [
                {
                  quantity: 5,
                  output_label: 'PAN111',
                  products: { code: 'PAN111' },
                },
              ],
            },
          ],
        }),
        batch(500, 'ready_for_cutting', {
          id: 'batch-2',
          products: { variant: 'D' },
          production_round_blocks: [{ weight_kg: 70 }],
          production_round_packing_entries: [
            { cases: 6, loose_packets: 0, skus: { code: 'MPAN400' } },
            { cases: 2, loose_packets: 1, skus: { code: 'MPAN100' } },
          ],
        }),
      ],
    };

    const summary = summarizeMilkLotProduction(lot);
    expect(summary).toMatchObject({
      milkConsumedLitres: 1_000,
      paneerProducedKg: 145,
      dRounds: 1,
      csRounds: 1,
      creamKg: 15.5,
      skuTotals: [
        { skuCode: 'MPAN100', cases: 2, loosePackets: 1 },
        { skuCode: 'MPAN400', cases: 10, loosePackets: 2 },
      ],
      pan111Kg: 5,
      sppPaneerKg: 75,
    });
    expect(summary.litresPerKg).toBeCloseTo(1_000 / 145);
    expect(summary.yieldKgPer100L).toBeCloseTo(14.5);
  });
});
