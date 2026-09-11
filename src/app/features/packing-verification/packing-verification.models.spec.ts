import { describe, expect, it } from 'vitest';
import {
  buildPackingVerificationView,
  caseWeightFromPackets,
  distributionPacketTotal,
  hasPackingVariance,
  packetsFromCaseWeight,
  type PackedRoundEntry,
  type PackingVerification,
  verifiedPacketTotal,
} from './packing-verification.models';

function entry(overrides: Partial<PackedRoundEntry> = {}): PackedRoundEntry {
  return {
    id: 'entry-1',
    production_batch_id: 'batch-1',
    sku_id: 'sku-1',
    cases: 3,
    loose_packets: 2,
    recorded_at: '2026-09-10T08:00:00Z',
    production_batches: {
      batch_code: '100926-S02-R01-D',
      round_number: 1,
      products: { name: 'Malai Paneer', variant: 'D' },
      production_shifts: { shift_number: 2, shift_members: [{ person_name: 'Team A' }] },
    },
    skus: {
      code: 'MPAN400',
      description: 'Malai Paneer 400 g',
      unit_weight_g: 400,
      packaging_configs: [
        {
          packets_per_case: 24,
          nominal_case_weight_kg: 9.6,
          variable_case_allowed: false,
          effective_from: '2026-01-01',
          effective_to: null,
        },
      ],
    },
    ...overrides,
  };
}

function verification(overrides: Partial<PackingVerification> = {}): PackingVerification {
  return {
    id: 'verification-1',
    sku_id: 'sku-1',
    declared_cases: 5,
    declared_loose_packets: 3,
    corrected_cases: 4,
    corrected_loose_packets: 6,
    packets_per_case_used: 24,
    case_weight_kg_used: 9.6,
    verified_packet_quantity: 102,
    source_round_uncertain: true,
    correction_reason: 'Some tray labels could not be confirmed',
    distributed_cases: 0,
    distributed_loose_packets: 0,
    distributed_packet_quantity: 0,
    retained_loose_packets: 0,
    distribution_exception_reason: null,
    status: 'verified',
    verified_at: '2026-09-10T10:00:00Z',
    sent_to_distribution_at: null,
    ...overrides,
  };
}

describe('packing verification helpers', () => {
  it('combines the same SKU across different rounds while retaining round contributions', () => {
    const view = buildPackingVerificationView(
      [
        entry(),
        entry({
          id: 'entry-2',
          production_batch_id: 'batch-2',
          cases: 2,
          loose_packets: 1,
          recorded_at: '2026-09-10T09:00:00Z',
          production_batches: {
            batch_code: '100926-S02-R02-D',
            round_number: 2,
            products: { name: 'Malai Paneer', variant: 'D' },
            production_shifts: { shift_number: 2, shift_members: [{ person_name: 'Team A' }] },
          },
        }),
      ],
      [],
      [],
    );

    expect(view.activeRows).toHaveLength(1);
    expect(view.activeRows[0]).toMatchObject({
      skuCode: 'MPAN400',
      declaredCases: 5,
      declaredLoosePackets: 3,
      correctedCases: 5,
      correctedLoosePackets: 3,
      entryCount: 2,
    });
    expect(view.activeRows[0].contributions).toHaveLength(2);
  });

  it('marks a verified SKU for rechecking when new packing is added', () => {
    const currentVerification = verification({
      declared_cases: 3,
      declared_loose_packets: 2,
      corrected_cases: 3,
      corrected_loose_packets: 2,
      source_round_uncertain: false,
      correction_reason: null,
    });
    const view = buildPackingVerificationView(
      [entry(), entry({ id: 'new-entry', production_batch_id: 'batch-2', cases: 1 })],
      [currentVerification],
      [
        {
          verification_id: currentVerification.id,
          packing_entry_id: 'entry-1',
          production_batch_id: 'batch-1',
          declared_cases: 3,
          declared_loose_packets: 2,
        },
      ],
    );

    expect(view.activeRows[0].needsReverification).toBe(true);
    expect(view.activeRows[0].declaredCases).toBe(4);
  });

  it('moves distributed entries out of active stock while preserving SKU history', () => {
    const sent = verification({
      status: 'sent_to_distribution',
      sent_to_distribution_at: '2026-09-10T11:00:00Z',
    });
    const view = buildPackingVerificationView(
      [entry()],
      [sent],
      [
        {
          verification_id: sent.id,
          packing_entry_id: 'entry-1',
          production_batch_id: 'batch-1',
          declared_cases: 3,
          declared_loose_packets: 2,
        },
      ],
    );

    expect(view.activeRows).toHaveLength(0);
    expect(view.historyRows).toHaveLength(1);
    expect(view.historyRows[0].contributions[0]).toMatchObject({
      shiftNumber: 2,
      roundNumber: 1,
    });
  });

  it('keeps corrections and the uncertain-source flag separate from declared totals', () => {
    const currentVerification = verification();
    const row = buildPackingVerificationView(
      [entry({ cases: 5, loose_packets: 3 })],
      [currentVerification],
      [
        {
          verification_id: currentVerification.id,
          packing_entry_id: 'entry-1',
          production_batch_id: 'batch-1',
          declared_cases: 5,
          declared_loose_packets: 3,
        },
      ],
    ).activeRows[0];

    expect(hasPackingVariance(row)).toBe(true);
    expect(row.sourceRoundUncertain).toBe(true);
    expect(verifiedPacketTotal(row)).toBe(102);
    expect(distributionPacketTotal(row)).toBe(96);
    expect(distributionPacketTotal(row, true)).toBe(102);
  });

  it('allows a variable-case SKU to receive its case size during verification', () => {
    const row = buildPackingVerificationView(
      [
        entry({
          skus: {
            code: 'MPAN010',
            description: 'Fresh Malai Paneer Block',
            unit_weight_g: 400,
            packaging_configs: [
              {
                packets_per_case: null,
                nominal_case_weight_kg: null,
                variable_case_allowed: true,
                effective_from: '2026-01-01',
                effective_to: null,
              },
            ],
          },
        }),
      ],
      [],
      [],
    ).activeRows[0];

    expect(row.variableCaseAllowed).toBe(true);
    expect(row.packetsPerCase).toBeNull();
    expect(row.caseWeightKg).toBeNull();
    expect(verifiedPacketTotal({ ...row, packetsPerCase: 50 })).toBe(152);
  });

  it('converts between MPAN010 case weight and whole packet quantity', () => {
    expect(packetsFromCaseWeight(20, 400)).toBe(50);
    expect(caseWeightFromPackets(50, 400)).toBe(20);
    expect(packetsFromCaseWeight(19.6, 400)).toBe(49);
  });
});
