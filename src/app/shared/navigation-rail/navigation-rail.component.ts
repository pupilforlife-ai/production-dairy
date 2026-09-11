import { Component, inject } from '@angular/core';
import { RouterLink, RouterLinkActive } from '@angular/router';
import { environment } from '../../../environment';
import { AuthService } from '../../core/auth/auth.service';

@Component({
  selector: 'app-navigation-rail',
  imports: [RouterLink, RouterLinkActive],
  templateUrl: './navigation-rail.component.html',
})
export class NavigationRailComponent {
  readonly auth = inject(AuthService);
  readonly betaMode = environment.betaMode;
  readonly homeLink = environment.betaMode ? '/production-board' : '/';
}
