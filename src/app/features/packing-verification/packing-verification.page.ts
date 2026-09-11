import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  buildPackingVerificationView,
  caseWeightFromPackets,
  hasPackingVariance,
  packetsFromCaseWeight,
  type LooseStockConsolidationHistory,
  type LooseStockPool,
  type SkuPackingVerificationRow,
  verifiedPacketTotal,
} from './packing-verification.models';
import { PackingVerificationService } from './packing-verification.service';

@Component({
  selector: 'app-packing-verification-page',
  imports: [DatePipe, DecimalPipe, RouterLink, NavigationRailComponent],
  templateUrl: './packing-verification.page.html',
})
export class PackingVerificationPage implements OnInit {
  private readonly service = inject(PackingVerificationService);
  readonly auth = inject(AuthService);
  readonly rows = signal<SkuPackingVerificationRow[]>([]);
  readonly historyRows = signal<SkuPackingVerificationRow[]>([]);
  readonly loosePools = signal<LooseStockPool[]>([]);
  readonly consolidationHistory = signal<LooseStockConsolidationHistory[]>([]);
  readonly consolidationCaseQuantities = signal<Record<string, number>>({});
  readonly pendingConsolidationSkuId = signal<string | null>(null);
  readonly consolidatingSkuId = signal<string | null>(null);
  readonly expandedKeys = signal<Set<string>>(new Set());
  readonly loading = signal(true);
  readonly savingKey = signal<string | null>(null);
  readonly sendingKey = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly rowErrorKey = signal<string | null>(null);
  readonly rowErrorMessage = signal<string | null>(null);
  readonly canVerify = computed(() => this.auth.hasRole('owner', 'admin'));
  readonly pendingCount = computed(
    () => this.rows().filter((row) => row.verification === null || row.needsReverification).length,
  );
  readonly verifiedCount = computed(
    () => this.rows().filter((row) => row.verification !== null && !row.needsReverification).length,
  );
  readonly sentCount = computed(() => this.historyRows().length);
  readonly uncertainCount = computed(
    () =>
      [...this.rows(), ...this.historyRows()].filter(
        (row) => row.verification?.source_round_uncertain,
      ).length,
  );

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  updateNumber(
    row: SkuPackingVerificationRow,
    field: 'correctedCases' | 'correctedLoosePackets',
    value: string,
  ): void {
    const parsed = Number(value);
    this.updateRow(row.key, {
      [field]: Number.isFinite(parsed) ? Math.max(0, Math.trunc(parsed)) : 0,
    });
  }

  updatePacketsPerCase(row: SkuPackingVerificationRow, value: string): void {
    const parsed = Number(value);
    const packetsPerCase =
      value === '' || !Number.isFinite(parsed) ? null : Math.max(1, Math.trunc(parsed));
    this.updateRow(row.key, {
      packetsPerCase,
      caseWeightKg: caseWeightFromPackets(packetsPerCase, row.unitWeightG) ?? row.caseWeightKg,
    });
  }

  updateCaseWeight(row: SkuPackingVerificationRow, value: string): void {
    const parsed = Number(value);
    const caseWeightKg = value === '' || !Number.isFinite(parsed) ? null : Math.max(0, parsed);
    this.updateRow(row.key, {
      caseWeightKg,
      packetsPerCase: packetsFromCaseWeight(caseWeightKg, row.unitWeightG) ?? row.packetsPerCase,
    });
  }

  updateUncertain(row: SkuPackingVerificationRow, checked: boolean): void {
    this.updateRow(row.key, { sourceRoundUncertain: checked });
  }

  updateReason(row: SkuPackingVerificationRow, reason: string): void {
    this.updateRow(row.key, { correctionReason: reason });
  }

  updateDistributionException(
    row: SkuPackingVerificationRow,
    changes: Partial<
      Pick<SkuPackingVerificationRow, 'includeLooseInDistribution' | 'distributionExceptionReason'>
    >,
  ): void {
    this.updateRow(row.key, changes);
  }

  hasVariance(row: SkuPackingVerificationRow): boolean {
    return hasPackingVariance(row);
  }

  packetTotal(row: SkuPackingVerificationRow): number | null {
    return verifiedPacketTotal(row);
  }

  isExpanded(row: SkuPackingVerificationRow): boolean {
    return this.expandedKeys().has(row.key);
  }

  toggleExpanded(row: SkuPackingVerificationRow): void {
    this.expandedKeys.update((keys) => {
      const next = new Set(keys);
      if (next.has(row.key)) next.delete(row.key);
      else next.add(row.key);
      return next;
    });
  }

  async verify(row: SkuPackingVerificationRow): Promise<void> {
    this.clearMessages();
    if (row.correctedCases > 0 && (!row.packetsPerCase || row.packetsPerCase <= 0)) {
      this.setRowError(
        row,
        row.variableCaseAllowed
          ? `Enter how many packets are in each ${row.skuCode} case before verification.`
          : `${row.skuCode} needs a packets-per-case configuration before cases can be verified. You can still verify loose packets only.`,
      );
      return;
    }
    if (row.variableCaseAllowed && row.correctedCases > 0 && !row.caseWeightKg) {
      this.setRowError(row, `Enter the ${row.skuCode} case weight before verification.`);
      return;
    }
    if ((hasPackingVariance(row) || row.sourceRoundUncertain) && !row.correctionReason.trim()) {
      this.setRowError(row, 'Enter a reason for every correction or uncertain source round.');
      return;
    }

    this.savingKey.set(row.key);
    try {
      await this.service.verify({
        skuId: row.skuId,
        correctedCases: row.correctedCases,
        correctedLoosePackets: row.correctedLoosePackets,
        packetsPerCase: row.variableCaseAllowed ? row.packetsPerCase : null,
        caseWeightKg: row.variableCaseAllowed ? row.caseWeightKg : null,
        sourceRoundUncertain: row.sourceRoundUncertain,
        correctionReason: row.correctionReason,
      });
      this.successMessage.set(
        `${row.skuCode} verified across ${row.contributions.length} contributing rounds.`,
      );
      await this.load(false);
    } catch (error) {
      this.setRowError(row, this.messageFrom(error));
    } finally {
      this.savingKey.set(null);
    }
  }

  async sendToDistribution(row: SkuPackingVerificationRow): Promise<void> {
    if (!row.verification || row.needsReverification) return;
    this.clearMessages();
    if (
      row.includeLooseInDistribution &&
      row.correctedLoosePackets > 0 &&
      !row.distributionExceptionReason.trim()
    ) {
      this.setRowError(row, 'Enter a reason to send loose packets as an exception.');
      return;
    }
    this.sendingKey.set(row.key);
    try {
      await this.service.sendToDistribution(
        row.verification.id,
        row.includeLooseInDistribution,
        row.distributionExceptionReason,
      );
      this.successMessage.set(
        row.includeLooseInDistribution && row.correctedLoosePackets > 0
          ? `${row.skuCode} full cases and approved loose packets sent to distribution.`
          : `${row.skuCode} full cases sent; loose packets remain in finished production.`,
      );
      await this.load(false);
    } catch (error) {
      this.setRowError(row, this.messageFrom(error));
    } finally {
      this.sendingKey.set(null);
    }
  }

  async sendRetainedLoose(row: SkuPackingVerificationRow): Promise<void> {
    if (!row.verification || row.verification.retained_loose_packets <= 0) return;
    this.clearMessages();
    if (!row.distributionExceptionReason.trim()) {
      this.setRowError(row, 'Enter a reason to release retained loose packets.');
      return;
    }
    this.sendingKey.set(row.key);
    try {
      await this.service.sendRetainedLooseToDistribution(
        row.verification.id,
        row.distributionExceptionReason,
      );
      this.successMessage.set(`${row.skuCode} retained loose packets sent by exception.`);
      await this.load(false);
    } catch (error) {
      this.setRowError(row, this.messageFrom(error));
    } finally {
      this.sendingKey.set(null);
    }
  }

  consolidationCases(pool: LooseStockPool): number {
    return this.consolidationCaseQuantities()[pool.sku_id] ?? pool.possible_cases;
  }

  updateConsolidationCases(pool: LooseStockPool, value: string): void {
    const parsed = Number(value);
    this.consolidationCaseQuantities.update((quantities) => ({
      ...quantities,
      [pool.sku_id]: Number.isFinite(parsed) ? Math.max(1, Math.trunc(parsed)) : 1,
    }));
  }

  startConsolidation(pool: LooseStockPool): void {
    this.clearMessages();
    this.consolidationCaseQuantities.update((quantities) => ({
      ...quantities,
      [pool.sku_id]: pool.possible_cases,
    }));
    this.pendingConsolidationSkuId.set(pool.sku_id);
  }

  cancelConsolidation(): void {
    this.pendingConsolidationSkuId.set(null);
  }

  async consolidateLooseStock(pool: LooseStockPool): Promise<void> {
    const caseQuantity = this.consolidationCases(pool);
    this.clearMessages();
    if (caseQuantity <= 0 || caseQuantity > pool.possible_cases) {
      this.errorMessage.set(
        `Choose between 1 and ${pool.possible_cases} full cases for ${pool.sku_code}.`,
      );
      return;
    }

    this.consolidatingSkuId.set(pool.sku_id);
    try {
      await this.service.consolidateLooseStock(pool.sku_id, caseQuantity);
      this.successMessage.set(
        `${caseQuantity} consolidated ${pool.sku_code} ${caseQuantity === 1 ? 'case' : 'cases'} sent to distribution with source traceability retained.`,
      );
      this.pendingConsolidationSkuId.set(null);
      await this.load(false);
    } catch (error) {
      this.errorMessage.set(this.messageFrom(error));
    } finally {
      this.consolidatingSkuId.set(null);
    }
  }

  private async load(showLoading = true): Promise<void> {
    if (showLoading) this.loading.set(true);
    try {
      const data = await this.service.load();
      const view = buildPackingVerificationView(data.entries, data.verifications, data.sources);
      this.rows.set(view.activeRows);
      this.historyRows.set(view.historyRows);
      this.loosePools.set(data.loosePools);
      this.consolidationHistory.set(data.consolidations);
    } catch (error) {
      this.errorMessage.set(this.messageFrom(error));
    } finally {
      this.loading.set(false);
    }
  }

  private updateRow(key: string, changes: Partial<SkuPackingVerificationRow>): void {
    this.rows.update((rows) => rows.map((row) => (row.key === key ? { ...row, ...changes } : row)));
    this.historyRows.update((rows) =>
      rows.map((row) => (row.key === key ? { ...row, ...changes } : row)),
    );
  }

  private clearMessages(): void {
    this.errorMessage.set(null);
    this.successMessage.set(null);
    this.rowErrorKey.set(null);
    this.rowErrorMessage.set(null);
  }

  private setRowError(row: SkuPackingVerificationRow, message: string): void {
    this.rowErrorKey.set(row.key);
    this.rowErrorMessage.set(message);
    this.errorMessage.set(message);
  }

  private messageFrom(error: unknown): string {
    if (error instanceof Error) return error.message;
    if (typeof error === 'object' && error !== null) {
      const response = error as {
        message?: unknown;
        details?: unknown;
        hint?: unknown;
        code?: unknown;
      };
      const parts = [response.message, response.details, response.hint].filter(
        (value): value is string => typeof value === 'string' && value.trim().length > 0,
      );
      if (parts.length > 0) return [...new Set(parts)].join(' — ');
      if (typeof response.code === 'string')
        return `Packing verification failed (${response.code}).`;
    }
    return typeof error === 'string' ? error : 'Packing verification failed. Please try again.';
  }
}
