import { Component, inject } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';
import { environment } from '../../../environment';
import { AuthService } from '../../core/auth/auth.service';
import { ThemeService } from '../../core/theme/theme.service';
import type { AppTheme } from '../../core/theme/theme.models';

@Component({
  selector: 'app-navigation-rail',
  imports: [RouterLink, RouterLinkActive],
  templateUrl: './navigation-rail.component.html',
})
export class NavigationRailComponent {
  readonly auth = inject(AuthService);
  readonly theme = inject(ThemeService);
  readonly betaMode = environment.betaMode;
  readonly homeLink = environment.betaMode ? '/production-board' : '/';

  setTheme(value: string): void {
    this.theme.setTheme(value as AppTheme);
  }
}
