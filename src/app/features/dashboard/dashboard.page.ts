import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import { productionStatusLabel } from '../production-board/production-board.models';
import {
  calculateMilkUsage,
  groupRoundsByShift,
  type DashboardMilkLot,
  type DashboardProductionBatch,
  type LatestMilkDashboardData,
} from './dashboard.models';
import { DashboardService } from './dashboard.service';

@Component({
  selector: 'app-dashboard-page',
  imports: [DatePipe, DecimalPipe, NavigationRailComponent],
  templateUrl: './dashboard.page.html',
})
export class DashboardPage implements OnInit {
  private readonly dashboard = inject(DashboardService);
  readonly auth = inject(AuthService);
  readonly loading = signal(true);
  readonly showMilkDetails = signal(false);
  readonly showPackedOutput = signal(false);
  readonly latestMilkProduction = computed(() => {
    const totals = new Map<string, number>();
    for (const batch of this.batches()) {
      const day = `Shift ${batch.production_shifts?.shift_number ?? '—'}`;
      const blocks = (batch.production_round_blocks || []).reduce(
        (sum, block) => sum + Number(block.weight_kg || 0),
        0,
      );
      totals.set(day, (totals.get(day) || 0) + Number(batch.gross_output_quantity || blocks));
    }
    return [...totals.entries()].sort((a, b) => {
      const shiftA = Number(a[0].replace('Shift ', ''));
      const shiftB = Number(b[0].replace('Shift ', ''));
      return shiftA - shiftB;
    });
  });
  readonly weeklyPaneerYield = computed(() => {
    const paneerMilk = this.batches()
      .filter((batch) => ['D', 'C/S'].includes(batch.products?.variant || ''))
      .reduce((sum, batch) => sum + Number(batch.actual_primary_input_quantity || 0), 0);
    return paneerMilk > 0 ? (this.packedOutput() / paneerMilk) * 100 : 0;
  });
  barHeight(value: number): number {
    return Math.max(8, (value / (this.packedOutput() || 1)) * 100);
  }
  readonly milkLot = signal<DashboardMilkLot | null>(null);
  readonly batches = signal<DashboardProductionBatch[]>([]);
  readonly finishedLots = signal<LatestMilkDashboardData['finishedLots']>([]);
  readonly packingVerifications = signal<LatestMilkDashboardData['packingVerifications']>([]);
  readonly errorMessage = signal<string | null>(null);
  readonly statusLabel = productionStatusLabel;
  readonly milkUsage = computed(() =>
    calculateMilkUsage(
      this.milkLot()?.received_quantity ?? 0,
      this.batches(),
      this.milkLot()?.source_lot_milk_sales ?? [],
    ),
  );
  readonly shiftSummaries = computed(() => groupRoundsByShift(this.batches()));
  readonly packedOutput = computed(() =>
    this.boardSkuTotals().reduce((total, item) => total + item.weight, 0),
  );
  readonly boardSkuTotals = computed(() => {
    const totals = new Map<string, { label: string; weight: number }>();
    for (const batch of this.batches()) {
      for (const entry of batch.production_round_packing_entries ?? []) {
        const sku = entry.skus;
        if (!sku?.code) continue;
        const packetWeight = Number(sku.unit_weight_g || 0) / 1000;
        const packetsPerCase = Number(sku.packaging_configs?.[0]?.packets_per_case || 0);
        const caseWeight = Number(sku.packaging_configs?.[0]?.nominal_case_weight_kg || 0);
        const knownCaseWeight = ['MPAN010', 'RPAN010'].includes(sku.code) ? 20 : 0;
        const weight =
          Number(entry.cases || 0) *
            (caseWeight || knownCaseWeight || packetsPerCase * packetWeight) +
          Number(entry.loose_packets || 0) * packetWeight;
        const current = totals.get(sku.code);
        totals.set(sku.code, {
          label: sku.products?.name || sku.description || sku.code,
          weight: (current?.weight || 0) + weight,
        });
      }
    }
    return [...totals.values()];
  });
  readonly packedOutputByProduct = computed(() => {
    return this.boardSkuTotals()
      .map((item) => [item.label, item.weight] as [string, number])
      .sort((left, right) => right[1] - left[1]);
  });
  readonly activeRoundCount = computed(
    () =>
      this.batches().filter((batch) => !['handed_over', 'cancelled'].includes(batch.status)).length,
  );

  async ngOnInit(): Promise<void> {
    try {
      const data = await this.dashboard.loadLatestMilk();
      this.milkLot.set(data.milkLot);
      this.batches.set(data.batches);
      this.finishedLots.set(data.finishedLots);
      this.packingVerifications.set(data.packingVerifications);
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
}
