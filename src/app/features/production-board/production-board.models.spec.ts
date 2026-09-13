import { describe, expect, it } from 'vitest';
import {
  CUT_FORMAT_OPTIONS,
  buildBatchCode,
  formatRemainingTime,
  getStageTimer,
  isDateInCurrentWeek,
  productionStatusLabel,
  receivedDateBatchCode,
  summarizeBlockWeights,
  summarizeCreamBuckets,
  summarizeIngredientIssues,
} from './production-board.models';

describe('production board helpers', () => {
  it('includes cling wrapping as a temporary cutting-stage option', () => {
    expect(CUT_FORMAT_OPTIONS).toContainEqual({
      value: 'cling_wrapped',
      label: 'Temporary: cling wrapped in chiller',
    });
  });

  it('builds the familiar batch hierarchy code', () => {
    expect(buildBatchCode('230826', 4, 3, 'D')).toBe('230826-S04-R03-D');
    expect(buildBatchCode('milk 7', 1, 12, 'C/S')).toBe('MILK-7-S01-R12-CS');
  });

  it('formats a production status', () => {
    expect(productionStatusLabel('ready_for_cutting')).toBe('Ready for cutting');
  });

  it('recognises dates in the current Monday-to-Sunday week', () => {
    const now = new Date('2026-09-04T12:00:00+02:00');
    expect(isDateInCurrentWeek('2026-08-31T00:00:00+02:00', now)).toBe(true);
    expect(isDateInCurrentWeek('2026-09-07T00:00:00+02:00', now)).toBe(false);
  });

  it('uses the South African milk receiving date as the visible batch code', () => {
    expect(receivedDateBatchCode('2026-09-05T22:30:00.000Z')).toBe('060926');
  });

  it('tracks the 2-hour chiller timer without changing the stage', () => {
    const timer = getStageTimer(
      'chiller',
      '2026-09-06T08:00:00+02:00',
      new Date('2026-09-06T09:31:00+02:00'),
    );
    expect(timer).toMatchObject({
      ready: false,
      prompt: 'Ready to take out',
      remainingMinutes: 29,
    });
    expect(formatRemainingTime(timer!.remainingMinutes)).toBe('29m remaining');
  });

  it('highlights resting rounds as ready for cutting after 90 minutes', () => {
    expect(
      getStageTimer('resting', '2026-09-06T08:00:00+02:00', new Date('2026-09-06T09:30:00+02:00')),
    ).toMatchObject({ ready: true, prompt: 'Ready for cutting', remainingMinutes: 0 });
    expect(getStageTimer('vat_2', '2026-09-06T08:00:00+02:00')).toBeNull();
  });

  it('uses 90 minutes for the cooling tank prompt', () => {
    expect(
      getStageTimer(
        'cooling_tank',
        '2026-09-06T08:00:00+02:00',
        new Date('2026-09-06T09:30:00+02:00'),
      ),
    ).toMatchObject({ ready: true, prompt: 'Ready to take out', remainingMinutes: 0 });
  });

  it('uses 30 minutes for pressing before prompting for cooling', () => {
    expect(
      getStageTimer('presses', '2026-09-06T08:00:00+02:00', new Date('2026-09-06T08:30:00+02:00')),
    ).toMatchObject({ ready: true, prompt: 'Ready for cooling', remainingMinutes: 0 });
  });

  it('summarises exact block weights and flags only weights above 13 kg', () => {
    const summary = summarizeBlockWeights(3, [
      {
        id: '1',
        production_batch_id: 'round',
        block_number: 1,
        weight_kg: 12,
        updated_at: '2026-09-06T08:00:00Z',
      },
      {
        id: '2',
        production_batch_id: 'round',
        block_number: 2,
        weight_kg: 13,
        updated_at: '2026-09-06T08:00:00Z',
      },
      {
        id: '3',
        production_batch_id: 'round',
        block_number: 3,
        weight_kg: 13.25,
        updated_at: '2026-09-06T08:00:00Z',
      },
    ]);

    expect(summary).toMatchObject({
      expectedCount: 3,
      recordedCount: 3,
      totalWeightKg: 38.25,
      averageWeightKg: 12.75,
      anomalyCount: 1,
      complete: true,
    });
  });

  it('totals multiple cream buckets from one C/S round', () => {
    const shared = {
      production_batch_id: 'round',
      recorded_at: '2026-09-06T08:00:00Z',
      intermediate_lots: {
        lot_code: 'ROUND-RC',
        storage_locations: { name: 'Dairy Container' },
      },
      profiles: { display_name: 'Worker' },
    };
    expect(
      summarizeCreamBuckets([
        { ...shared, id: '1', bucket_number: 1, weight_kg: 8.25 },
        { ...shared, id: '2', bucket_number: 2, weight_kg: 7.5 },
        { ...shared, id: '3', bucket_number: 3, weight_kg: 8 },
      ]),
    ).toEqual({ count: 3, totalWeightKg: 23.75 });
  });

  it('summarises ingredient shortages without changing process eligibility', () => {
    const shared = {
      production_batch_id: 'round',
      addition_stage: 'processing_vat' as const,
      last_attempted_at: '2026-09-07T10:00:00Z',
      units_of_measure: { code: 'kg' },
      recipe_components: { ingredients: { name: 'Cream powder' } },
    };
    expect(
      summarizeIngredientIssues([
        {
          ...shared,
          id: '1',
          required_quantity: 5,
          issued_quantity: 5,
          shortage_quantity: 0,
        },
        {
          ...shared,
          id: '2',
          required_quantity: 2,
          issued_quantity: 0.5,
          shortage_quantity: 1.5,
        },
      ]),
    ).toEqual({ componentCount: 2, shortageCount: 1, hasShortage: true });
  });
});
