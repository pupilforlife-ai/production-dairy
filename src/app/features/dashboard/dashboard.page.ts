import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { Router } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import { productionStatusLabel } from '../production-board/production-board.models';
import {
  calculateMilkUsage,
  groupRoundsByShift,
  type DashboardMilkLot,
  type DashboardProductionBatch,
} from './dashboard.models';
import { DashboardService } from './dashboard.service';

@Component({
  selector: 'app-dashboard-page',
  imports: [DatePipe, DecimalPipe, NavigationRailComponent],
  templateUrl: './dashboard.page.html',
})
export class DashboardPage implements OnInit {
  private readonly router = inject(Router);
  private readonly dashboard = inject(DashboardService);
  readonly auth = inject(AuthService);
  readonly signingOut = signal(false);
  readonly loading = signal(true);
  readonly showMilkDetails = signal(false);
  readonly milkLot = signal<DashboardMilkLot | null>(null);
  readonly batches = signal<DashboardProductionBatch[]>([]);
  readonly errorMessage = signal<string | null>(null);
  readonly statusLabel = productionStatusLabel;
  readonly milkUsage = computed(() =>
    calculateMilkUsage(this.milkLot()?.received_quantity ?? 0, this.batches()),
  );
  readonly shiftSummaries = computed(() => groupRoundsByShift(this.batches()));

  async ngOnInit(): Promise<void> {
    try {
      const data = await this.dashboard.loadLatestMilk();
      this.milkLot.set(data.milkLot);
      this.batches.set(data.batches);
    } catch (error) {
      this.errorMessage.set(
        error && typeof error === 'object' && 'message' in error
          ? String(error.message)
          : 'Unable to load the factory dashboard.',
      );
    } finally {
      this.loading.set(false);
    }
  }

  async signOut(): Promise<void> {
    this.signingOut.set(true);
    try {
      await this.auth.signOut();
      await this.router.navigate(['/login']);
    } finally {
      this.signingOut.set(false);
    }
  }
}
