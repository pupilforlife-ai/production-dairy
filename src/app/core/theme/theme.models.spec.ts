import { describe, expect, it } from 'vitest';
import { isAppTheme, nextAppTheme } from './theme.models';

describe('app themes', () => {
  it('recognises supported themes', () => {
    expect(isAppTheme('dark')).toBe(true);
    expect(isAppTheme('light')).toBe(true);
    expect(isAppTheme('high-contrast')).toBe(true);
    expect(isAppTheme('unknown')).toBe(false);
  });

  it('cycles through every theme', () => {
    expect(nextAppTheme('dark')).toBe('light');
    expect(nextAppTheme('light')).toBe('high-contrast');
    expect(nextAppTheme('high-contrast')).toBe('dark');
  });
});
