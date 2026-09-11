import { describe, expect, it } from 'vitest';
import { PROCESS_TEMPLATES, processControlInSpec } from './transformation.models';

describe('transformation process configuration', () => {
  it('provides both documented popper frying workflows', () => {
    const fryingTemplates = PROCESS_TEMPLATES.filter((template) => template.type === 'frying');

    expect(fryingTemplates.map((template) => template.key)).toEqual(['spp-frying', 'jp-frying']);
    expect(fryingTemplates.every((template) => template.controls.length === 2)).toBe(true);
  });

  it('evaluates numeric process tolerances', () => {
    expect(processControlInSpec(185, 180, 190)).toBe(true);
    expect(processControlInSpec(195, 180, 190)).toBe(false);
    expect(processControlInSpec(null, 180, 190)).toBeNull();
  });
});
