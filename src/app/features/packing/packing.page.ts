import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  expectedPackedWeightKg,
  fifoSourceId,
  packetEquivalent,
  type FinishedStockLot,
  type PackingLocation,
  type PackingRunSummary,
  type PackingSku,
  type PackingSourceLot,
} from './packing.models';
import { PackingService } from './packing.service';

type PackingSourceForm = FormGroup<{
  intermediateLotId: FormControl<string>;
  quantity: FormControl<number | null>;
}>;

@Component({
  selector: 'app-packing-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './packing.page.html',
})
export class PackingPage implements OnInit {
  private readonly packingService = inject(PackingService);
  readonly skus = signal<PackingSku[]>([]);
  readonly sourceLots = signal<PackingSourceLot[]>([]);
  readonly locations = signal<PackingLocation[]>([]);
  readonly packingRuns = signal<PackingRunSummary[]>([]);
  readonly finishedLots = signal<FinishedStockLot[]>([]);
  readonly selectedSkuId = signal('');
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly showForm = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly availableFinishedPackets = computed(() =>
    this.finishedLots()
      .filter((lot) => lot.status === 'available')
      .reduce((total, lot) => total + Number(lot.current_packet_quantity), 0),
  );

  readonly packingSources = new FormArray<PackingSourceForm>([this.createSourceForm()]);
  readonly form = new FormGroup({
    skuId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    completedAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    operatorTeam: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    cases: new FormControl<number | null>(0, [Validators.required, Validators.min(0)]),
    looseUnits: new FormControl<number | null>(0, [Validators.required, Validators.min(0)]),
    packetsPerCaseOverride: new FormControl<number | null>(null, [Validators.min(1)]),
    actualPackedWeightKg: new FormControl<number | null>(null, [Validators.min(0.001)]),
    wrappersUsed: new FormControl<number | null>(null, [Validators.min(0.001)]),
    casesUsed: new FormControl<number | null>(null, [Validators.min(0.001)]),
    destinationLocationId: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    fifoOverrideReason: new FormControl('', { nonNullable: true }),
    weightVarianceReason: new FormControl('', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
    sources: this.packingSources,
  });

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  selectSku(skuId: string): void {
    this.selectedSkuId.set(skuId);
    while (this.packingSources.length > 1) this.packingSources.removeAt(1);
    this.packingSources.at(0).reset({ intermediateLotId: '', quantity: null });
    const fifoId = this.fifoRecommendedId();
    if (fifoId) this.packingSources.at(0).controls.intermediateLotId.setValue(fifoId);
    this.form.controls.packetsPerCaseOverride.setValue(null);
    this.form.controls.actualPackedWeightKg.setValue(null);
  }

  addSource(): void {
    this.packingSources.push(this.createSourceForm());
  }

  removeSource(index: number): void {
    if (this.packingSources.length > 1) this.packingSources.removeAt(index);
  }

  fillAvailable(index: number, lotId: string): void {
    const lot = this.sourceLots().find((item) => item.id === lotId);
    if (lot) this.packingSources.at(index).controls.quantity.setValue(Number(lot.current_quantity));
  }

  selectedSku(): PackingSku | null {
    return this.skus().find((sku) => sku.id === this.selectedSkuId()) ?? null;
  }

  eligibleSourceLots(): PackingSourceLot[] {
    const sku = this.selectedSku();
    if (!sku) return [];
    const freshPack = ['MPAN010', 'RPAN010'].includes(sku.code);
    return this.sourceLots().filter(
      (lot) =>
        lot.product_id === sku.product_id &&
        (freshPack || lot.storage_locations?.code === 'INTERMEDIATE_FREEZER'),
    );
  }

  fifoRecommendedId(): string | null {
    return fifoSourceId(this.eligibleSourceLots());
  }

  fifoOverridden(): boolean {
    const fifoId = this.fifoRecommendedId();
    if (!fifoId) return false;
    return !this.packingSources.controls.some(
      (source) => source.controls.intermediateLotId.value === fifoId,
    );
  }

  configuredPacketsPerCase(): number | null {
    const sku = this.selectedSku();
    if (!sku) return null;
    const now = new Date(this.form.controls.completedAt.value);
    const config = [...sku.packaging_configs]
      .filter(
        (item) =>
          new Date(item.effective_from) <= now &&
          (!item.effective_to || new Date(item.effective_to + 'T23:59:59') >= now),
      )
      .sort(
        (left, right) =>
          new Date(right.effective_from).getTime() - new Date(left.effective_from).getTime(),
      )[0];
    return config?.packets_per_case ?? null;
  }

  effectivePacketsPerCase(): number | null {
    return this.form.controls.packetsPerCaseOverride.value ?? this.configuredPacketsPerCase();
  }

  totalPackets(): number {
    return packetEquivalent(
      this.form.controls.cases.value,
      this.form.controls.looseUnits.value,
      this.effectivePacketsPerCase(),
    );
  }

  expectedWeight(): number {
    return expectedPackedWeightKg(this.totalPackets(), this.selectedSku()?.unit_weight_g ?? null);
  }

  actualWeight(): number {
    return Number(this.form.controls.actualPackedWeightKg.value || this.expectedWeight());
  }

  sourceTotal(): number {
    return this.packingSources.controls.reduce(
      (total, source) => total + Number(source.controls.quantity.value || 0),
      0,
    );
  }

  weightDifference(): number {
    return this.sourceTotal() - this.actualWeight();
  }

  async completePacking(): Promise<void> {
    if (this.form.invalid || this.saving()) {
      this.form.markAllAsTouched();
      return;
    }
    const values = this.form.getRawValue();
    const sources = values.sources
      .filter((source) => source.intermediateLotId && Number(source.quantity || 0) > 0)
      .map((source) => ({
        intermediateLotId: source.intermediateLotId,
        quantity: Number(source.quantity),
      }));
    if (this.totalPackets() <= 0) {
      this.errorMessage.set('Record at least one case or loose packet.');
      return;
    }
    if (Number(values.cases || 0) > 0 && !this.effectivePacketsPerCase()) {
      this.errorMessage.set('Enter packets per case for this variable packing configuration.');
      return;
    }
    if (!sources.length || sources.length !== values.sources.length) {
      this.errorMessage.set('Select a lot and positive quantity for every packing source.');
      return;
    }
    if (new Set(sources.map((source) => source.intermediateLotId)).size !== sources.length) {
      this.errorMessage.set('The same intermediate lot cannot be selected twice.');
      return;
    }
    if (this.actualWeight() <= 0) {
      this.errorMessage.set('Enter the actual packed weight for this SKU.');
      return;
    }
    if (this.actualWeight() > this.sourceTotal() && !values.weightVarianceReason.trim()) {
      this.errorMessage.set(
        'Packed weight exceeds consumed stock. Enter a variance reason to continue.',
      );
      return;
    }

    await this.runSave(async () => {
      await this.packingService.completePacking({
        skuId: values.skuId,
        completedAt: values.completedAt,
        operatorTeam: values.operatorTeam.trim(),
        cases: Number(values.cases || 0),
        looseUnits: Number(values.looseUnits || 0),
        packetsPerCaseOverride: values.packetsPerCaseOverride,
        actualPackedWeightKg: values.actualPackedWeightKg,
        sources,
        fifoOverrideReason: this.optional(values.fifoOverrideReason),
        weightVarianceReason: this.optional(values.weightVarianceReason),
        wrappersUsed: values.wrappersUsed,
        casesUsed: values.casesUsed,
        destinationLocationId: values.destinationLocationId,
        notes: this.optional(values.notes),
      });
      this.successMessage.set(
        Number(values.cases || 0) +
          ' cases and ' +
          Number(values.looseUnits || 0) +
          ' loose packets recorded.',
      );
      this.showForm.set(false);
      this.resetForm();
      await this.load(false);
    });
  }

  private async load(showLoading = true): Promise<void> {
    if (showLoading) this.loading.set(true);
    try {
      const data = await this.packingService.load();
      this.skus.set(data.skus);
      this.sourceLots.set(data.sourceLots);
      this.locations.set(data.locations);
      this.packingRuns.set(data.packingRuns);
      this.finishedLots.set(data.finishedLots);
      if (!this.form.controls.destinationLocationId.value && data.locations[0]) {
        this.form.controls.destinationLocationId.setValue(data.locations[0].id);
      }
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to load packing data.'));
    } finally {
      if (showLoading) this.loading.set(false);
    }
  }

  private async runSave(operation: () => Promise<void>): Promise<void> {
    this.saving.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await operation();
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to complete the packing run.'));
    } finally {
      this.saving.set(false);
    }
  }

  private resetForm(): void {
    while (this.packingSources.length > 1) this.packingSources.removeAt(1);
    this.selectedSkuId.set('');
    this.form.reset({
      skuId: '',
      completedAt: this.localDateTime(),
      operatorTeam: '',
      cases: 0,
      looseUnits: 0,
      packetsPerCaseOverride: null,
      actualPackedWeightKg: null,
      wrappersUsed: null,
      casesUsed: null,
      destinationLocationId: this.locations()[0]?.id || '',
      fifoOverrideReason: '',
      weightVarianceReason: '',
      notes: '',
      sources: [{ intermediateLotId: '', quantity: null }],
    });
  }

  private createSourceForm(): PackingSourceForm {
    return new FormGroup({
      intermediateLotId: new FormControl('', {
        nonNullable: true,
        validators: [Validators.required],
      }),
      quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
    });
  }

  private optional(value: string): string | null {
    return value.trim() || null;
  }

  private errorText(error: unknown, fallback: string): string {
    if (error && typeof error === 'object' && 'message' in error) {
      return String(error.message);
    }
    return fallback;
  }

  private localDateTime(): string {
    const date = new Date();
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
    return local.toISOString().slice(0, 16);
  }
}
