import { Component, inject, signal } from '@angular/core';
import { Router, RouterOutlet } from '@angular/router';
import { environment } from '../environment';
import { AuthService } from './core/auth/auth.service';
import { ThemeService } from './core/theme/theme.service';

@Component({
  selector: 'app-root',
  imports: [RouterOutlet],
  templateUrl: './app.html',
  styleUrl: './app.css',
})
export class App {
  private readonly router = inject(Router);
  readonly betaMode = environment.betaMode;
  readonly auth = inject(AuthService);
  readonly signingOut = signal(false);

  constructor() {
    inject(ThemeService);
  }

  async signOut(): Promise<void> {
    if (this.signingOut()) return;
    this.signingOut.set(true);
    try {
      await this.auth.signOut();
      await this.router.navigate(['/login']);
    } finally {
      this.signingOut.set(false);
    }
  }
}
