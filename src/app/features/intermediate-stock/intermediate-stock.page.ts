import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  fifoLotId,
  reconciledCuttingQuantity,
  type CuttingOutputInput,
  type IntermediateLotSummary,
  type ProductionBatchOption,
  type StorageLocationOption,
  type TransformationSummary,
} from './intermediate-stock.models';
import { IntermediateStockService } from './intermediate-stock.service';

type OutputKind = CuttingOutputInput['kind'];
type CuttingOutputForm = FormGroup<{
  kind: FormControl<OutputKind>;
  label: FormControl<string>;
  quantity: FormControl<number | null>;
  destinationLocationId: FormControl<string>;
}>;

@Component({
  selector: 'app-intermediate-stock-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './intermediate-stock.page.html',
})
export class IntermediateStockPage implements OnInit {
  private readonly stockService = inject(IntermediateStockService);
  readonly lots = signal<IntermediateLotSummary[]>([]);
  readonly locations = signal<StorageLocationOption[]>([]);
  readonly transformations = signal<TransformationSummary[]>([]);
  readonly productionBatches = signal<ProductionBatchOption[]>([]);
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly showCuttingForm = signal(false);
  readonly showRecoveredCreamForm = signal(false);
  readonly transferringLot = signal<IntermediateLotSummary | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly locationFilter = signal('');
  readonly productFilter = signal('');

  readonly availableLots = computed(() =>
    this.lots().filter((lot) => lot.current_quantity > 0 && lot.status !== 'depleted'),
  );
  readonly uncutLots = computed(() =>
    this.availableLots().filter((lot) => lot.source_transformation_id === null),
  );
  readonly filteredLots = computed(() =>
    this.availableLots().filter(
      (lot) =>
        (!this.locationFilter() || lot.storage_locations?.id === this.locationFilter()) &&
        (!this.productFilter() || lot.products?.code === this.productFilter()),
    ),
  );
  readonly fifoRecommendedId = computed(() => fifoLotId(this.availableLots()));
  readonly totalAvailable = computed(() =>
    this.availableLots().reduce((total, lot) => total + Number(lot.current_quantity), 0),
  );
  readonly pan111Available = computed(() =>
    this.availableLots()
      .filter((lot) => lot.products?.code === 'PAN111')
      .reduce((total, lot) => total + Number(lot.current_quantity), 0),
  );
  readonly productOptions = computed(() => {
    const products = new Map<string, string>();
    for (const lot of this.availableLots()) {
      if (lot.products) products.set(lot.products.code, lot.products.name);
    }
    return [...products.entries()].map(([code, name]) => ({ code, name }));
  });

  readonly cuttingOutputs = new FormArray<CuttingOutputForm>([this.createOutputForm()]);
  readonly cuttingForm = new FormGroup({
    sourceLotId: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    sourceQuantity: new FormControl<number | null>(null, [
      Validators.required,
      Validators.min(0.001),
    ]),
    occurredAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    performedBy: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    cutType: new FormControl('400 g', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    lossQuantity: new FormControl<number | null>(0, [Validators.min(0)]),
    lossReason: new FormControl('', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
    outputs: this.cuttingOutputs,
  });

  readonly transferForm = new FormGroup({
    quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
    destinationLocationId: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    reference: new FormControl('', { nonNullable: true }),
  });

  readonly recoveredCreamForm = new FormGroup({
    batchId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
    destinationLocationId: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    occurredAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    notes: new FormControl('', { nonNullable: true }),
  });

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  addOutput(kind: OutputKind = 'primary'): void {
    const output = this.createOutputForm(kind);
    const preferredLocation = this.preferredDestination();
    if (preferredLocation) output.controls.destinationLocationId.setValue(preferredLocation.id);
    this.cuttingOutputs.push(output);
  }

  removeOutput(index: number): void {
    if (this.cuttingOutputs.length > 1) this.cuttingOutputs.removeAt(index);
  }

  selectSource(lotId: string): void {
    const lot = this.lots().find((item) => item.id === lotId);
    if (lot) this.cuttingForm.controls.sourceQuantity.setValue(Number(lot.current_quantity));
  }

  cuttingReconciled(): number {
    return reconciledCuttingQuantity(
      this.cuttingOutputs.controls.map((control) => ({
        quantity: control.controls.quantity.value,
      })),
      this.cuttingForm.controls.lossQuantity.value,
    );
  }

  cuttingDifference(): number {
    return Number(this.cuttingForm.controls.sourceQuantity.value || 0) - this.cuttingReconciled();
  }

  cuttingIsReconciled(): boolean {
    return Math.abs(this.cuttingDifference()) <= 0.001;
  }

  async recordCutting(): Promise<void> {
    if (this.cuttingForm.invalid || this.saving()) {
      this.cuttingForm.markAllAsTouched();
      return;
    }
    const values = this.cuttingForm.getRawValue();
    if (values.sourceQuantity === null) return;
    const outputs = values.outputs
      .filter((output) => Number(output.quantity || 0) > 0)
      .map((output) => ({
        kind: output.kind,
        label: output.label.trim(),
        quantity: Number(output.quantity),
        destinationLocationId: output.destinationLocationId,
      }));
    if (
      outputs.length === 0 ||
      outputs.some((output) => !output.label || !output.destinationLocationId)
    ) {
      this.errorMessage.set('Enter a label, quantity, and location for every cutting output.');
      return;
    }
    if (Math.abs(this.cuttingDifference()) > 0.001) {
      this.errorMessage.set('Output quantities plus loss must equal the source weight.');
      return;
    }
    if (Number(values.lossQuantity || 0) > 0 && !values.lossReason.trim()) {
      this.errorMessage.set('Enter a reason for the recorded loss.');
      return;
    }

    await this.runSave(async () => {
      await this.stockService.recordCutting({
        sourceLotId: values.sourceLotId,
        sourceQuantity: values.sourceQuantity!,
        occurredAt: values.occurredAt,
        performedBy: values.performedBy.trim(),
        cutType: values.cutType,
        outputs,
        lossQuantity: Number(values.lossQuantity || 0),
        lossReason: this.optional(values.lossReason),
        notes: this.optional(values.notes),
      });
      this.successMessage.set('Cutting transaction recorded and stock balances updated.');
      this.showCuttingForm.set(false);
      this.resetCuttingForm();
      await this.load(false);
    });
  }

  beginTransfer(lot: IntermediateLotSummary): void {
    this.transferringLot.set(lot);
    this.transferForm.reset({
      quantity: Number(lot.current_quantity),
      destinationLocationId: '',
      reference: '',
    });
  }

  async transferStock(): Promise<void> {
    const lot = this.transferringLot();
    if (!lot || this.transferForm.invalid || this.saving()) {
      this.transferForm.markAllAsTouched();
      return;
    }
    const values = this.transferForm.getRawValue();
    if (values.quantity === null) return;
    if (values.destinationLocationId === lot.storage_locations?.id) {
      this.errorMessage.set('Choose a different destination location.');
      return;
    }

    await this.runSave(async () => {
      await this.stockService.transfer({
        lotId: lot.id,
        quantity: values.quantity!,
        destinationLocationId: values.destinationLocationId,
        reference: this.optional(values.reference),
      });
      this.successMessage.set(values.quantity + ' kg transferred from ' + lot.lot_code + '.');
      this.transferringLot.set(null);
      await this.load(false);
    });
  }

  async recordRecoveredCream(): Promise<void> {
    if (this.recoveredCreamForm.invalid || this.saving()) {
      this.recoveredCreamForm.markAllAsTouched();
      return;
    }
    const values = this.recoveredCreamForm.getRawValue();
    if (values.quantity === null) return;
    await this.runSave(async () => {
      await this.stockService.recordRecoveredCream({
        batchId: values.batchId,
        quantity: values.quantity!,
        destinationLocationId: values.destinationLocationId,
        occurredAt: values.occurredAt,
        notes: this.optional(values.notes),
      });
      this.successMessage.set('Recovered cream recorded as traceable intermediate stock.');
      this.showRecoveredCreamForm.set(false);
      this.recoveredCreamForm.reset({
        batchId: '',
        quantity: null,
        destinationLocationId: this.chillerLocation()?.id || '',
        occurredAt: this.localDateTime(),
        notes: '',
      });
      await this.load(false);
    });
  }

  private async load(showLoading = true): Promise<void> {
    if (showLoading) this.loading.set(true);
    try {
      const data = await this.stockService.load();
      this.lots.set(data.lots);
      this.locations.set(data.locations);
      this.transformations.set(data.transformations);
      this.productionBatches.set(data.productionBatches);
      const destination = this.preferredDestination();
      if (destination) {
        for (const output of this.cuttingOutputs.controls) {
          if (!output.controls.destinationLocationId.value) {
            output.controls.destinationLocationId.setValue(destination.id);
          }
        }
      }
      const chiller = this.chillerLocation();
      if (chiller && !this.recoveredCreamForm.controls.destinationLocationId.value) {
        this.recoveredCreamForm.controls.destinationLocationId.setValue(chiller.id);
      }
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to load intermediate stock.'));
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
      this.errorMessage.set(this.errorText(error, 'Unable to save the stock transaction.'));
    } finally {
      this.saving.set(false);
    }
  }

  private resetCuttingForm(): void {
    while (this.cuttingOutputs.length > 1) this.cuttingOutputs.removeAt(1);
    this.cuttingForm.reset({
      sourceLotId: '',
      sourceQuantity: null,
      occurredAt: this.localDateTime(),
      performedBy: '',
      cutType: '400 g',
      lossQuantity: 0,
      lossReason: '',
      notes: '',
      outputs: [
        {
          kind: 'primary',
          label: '',
          quantity: null,
          destinationLocationId: this.preferredDestination()?.id || '',
        },
      ],
    });
  }

  private createOutputForm(kind: OutputKind = 'primary'): CuttingOutputForm {
    return new FormGroup({
      kind: new FormControl(kind, { nonNullable: true }),
      label: new FormControl(kind === 'pan111' ? 'PAN111' : '', {
        nonNullable: true,
      }),
      quantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
      destinationLocationId: new FormControl('', { nonNullable: true }),
    });
  }

  private preferredDestination(): StorageLocationOption | undefined {
    return this.locations().find((location) => location.code === 'INTERMEDIATE_FREEZER');
  }

  private chillerLocation(): StorageLocationOption | undefined {
    return this.locations().find((location) => location.code === 'CHILLER');
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
