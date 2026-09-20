import { DOCUMENT } from '@angular/common';
import { Injectable, inject, signal } from '@angular/core';
import { APP_THEMES, isAppTheme, nextAppTheme, type AppTheme } from './theme.models';

const THEME_STORAGE_KEY = 'production-dairy-theme';

@Injectable({ providedIn: 'root' })
export class ThemeService {
  private readonly document = inject(DOCUMENT);
  private readonly selectedTheme = signal<AppTheme>(this.readStoredTheme());

  readonly theme = this.selectedTheme.asReadonly();
  readonly themes = APP_THEMES;

  constructor() {
    this.applyTheme(this.selectedTheme());
  }

  setTheme(theme: AppTheme): void {
    this.selectedTheme.set(theme);
    this.applyTheme(theme);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, theme);
    } catch {
      // The theme still applies when browser storage is unavailable.
    }
  }

  cycleTheme(): void {
    this.setTheme(nextAppTheme(this.selectedTheme()));
  }

  private applyTheme(theme: AppTheme): void {
    this.document.documentElement.dataset['theme'] = theme;
    this.document.documentElement.style.colorScheme =
      theme === 'light' || theme === 'qwen' ? 'light' : 'dark';
  }

  private readStoredTheme(): AppTheme {
    try {
      const storedTheme = localStorage.getItem(THEME_STORAGE_KEY);
      return isAppTheme(storedTheme) ? storedTheme : 'dark';
    } catch {
      return 'dark';
    }
  }
}
