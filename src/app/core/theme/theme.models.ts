export type AppTheme = 'dark' | 'light' | 'qwen' | 'high-contrast';

export const APP_THEMES: ReadonlyArray<{ value: AppTheme; label: string }> = [
  { value: 'dark', label: 'Dark' },
  { value: 'light', label: 'Light' },
  { value: 'qwen', label: 'Qwen style' },
  { value: 'high-contrast', label: 'High contrast' },
];

export function isAppTheme(value: string | null): value is AppTheme {
  return APP_THEMES.some((theme) => theme.value === value);
}

export function nextAppTheme(current: AppTheme): AppTheme {
  const currentIndex = APP_THEMES.findIndex((theme) => theme.value === current);
  return APP_THEMES[(currentIndex + 1) % APP_THEMES.length].value;
}
