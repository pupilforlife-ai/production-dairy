import { describe, expect, it } from 'vitest';
import { scaleComponent, validToleranceRange } from './recipe.models';

describe('scaleComponent', () => {
  it('scales the confirmed ghee formula proportionally', () => {
    expect(scaleComponent({ quantity: 92.5 }, 105, 210).quantity).toBe(185);
    expect(scaleComponent({ quantity: 12.5 }, 105, 210).quantity).toBe(25);
  });

  it('scales tolerances with the component quantity', () => {
    expect(scaleComponent({ quantity: 10, toleranceMin: 9, toleranceMax: 11 }, 100, 50)).toEqual({
      quantity: 5,
      toleranceMin: 4.5,
      toleranceMax: 5.5,
    });
  });

  it('rejects non-positive quantities', () => {
    expect(() => scaleComponent({ quantity: 10 }, 0, 50)).toThrow(
      'Recipe basis and requested quantity must be positive.',
    );
  });
});

describe('validToleranceRange', () => {
  it('allows partial ranges and rejects an inverted complete range', () => {
    expect(validToleranceRange(null, 5)).toBe(true);
    expect(validToleranceRange(4, 5)).toBe(true);
    expect(validToleranceRange(6, 5)).toBe(false);
  });
});
