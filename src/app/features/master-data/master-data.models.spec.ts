import { describe, expect, it } from 'vitest';
import { packagingDescription } from './master-data.models';

describe('packagingDescription', () => {
  it('describes a fixed case configuration', () => {
    expect(
      packagingDescription({
        units_per_inner_pack: 8,
        packets_per_case: 12,
        nominal_case_weight_kg: null,
        variable_case_allowed: false,
      }),
    ).toBe('8 units/packet · 12 packets/case');
  });

  it('does not invent a fixed configuration for variable cases', () => {
    expect(
      packagingDescription({
        units_per_inner_pack: 1,
        packets_per_case: null,
        nominal_case_weight_kg: null,
        variable_case_allowed: true,
      }),
    ).toBe('Variable case configuration');
  });
});
