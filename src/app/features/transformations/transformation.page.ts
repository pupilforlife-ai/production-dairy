import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  PROCESS_TEMPLATES,
  type ProcessControlPreset,
  type ProcessTemplate,
  type RecipeVersionOption,
  type SourceLotOption,
  type TransformationHistory,
  type TransformationInventoryBalance,
  type TransformationLocation,
  type TransformationLotOption,
  type TransformationProduct,
  type TransformationUnit,
} from './transformation.models';
import { TransformationService } from './transformation.service';

type IntermediateInputGroup = FormGroup<{
  lotId: FormControl<string>;
  quantity: FormControl<number | null>;
  standardQuantity: FormControl<number | null>;
}>;
type SourceLotInputGroup = FormGroup<{
  lotId: FormControl<string>;
  quantity: FormControl<number | null>;
}>;
type InventoryInputGroup = FormGroup<{
  balanceKey: FormControl<string>;
  quantity: FormControl<number | null>;
  standardQuantity: FormControl<number | null>;
}>;
type OutputGroup = FormGroup<{
  productId: FormControl<string>;
  quantity: FormControl<number | null>;
  uomId: FormControl<string>;
  locationId: FormControl<string>;
  kind: FormControl<string>;
  label: FormControl<string>;
}>;
type ControlGroup = FormGroup<{
  code: FormControl<string>;
  label: FormControl<string>;
  numericValue: FormControl<number | null>;
  textValue: FormControl<string>;
  uomLabel: FormControl<string>;
  targetValue: FormControl<number | null>;
  minValue: FormControl<number | null>;
  maxValue: FormControl<number | null>;
}>;

@Component({
  selector: 'app-transformation-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './transformation.page.html',
})
export class TransformationPage implements OnInit {
  private readonly transformationService = inject(TransformationService);
  readonly auth = inject(AuthService);
  readonly templates = PROCESS_TEMPLATES;
  readonly selectedTemplate = signal<ProcessTemplate>(PROCESS_TEMPLATES[0]);
  readonly lots = signal<TransformationLotOption[]>([]);
  readonly sourceLots = signal<SourceLotOption[]>([]);
  readonly inventoryBalances = signal<TransformationInventoryBalance[]>([]);
  readonly products = signal<TransformationProduct[]>([]);
  readonly units = signal<TransformationUnit[]>([]);
  readonly locations = signal<TransformationLocation[]>([]);
  readonly recipeVersions = signal<RecipeVersionOption[]>([]);
  readonly history = signal<TransformationHistory[]>([]);
  readonly showForm = signal(false);
  readonly expandedHistoryId = signal<string | null>(null);
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);

  readonly form = new FormGroup({
    templateKey: new FormControl(PROCESS_TEMPLATES[0].key, {
      nonNullable: true,
      validators: [Validators.required],
    }),
    occurredAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    performedBy: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    recipeVersionId: new FormControl('', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
    intermediateInputs: new FormArray<IntermediateInputGroup>([this.createIntermediateInput()]),
    sourceLotInputs: new FormArray<SourceLotInputGroup>([]),
    inventoryInputs: new FormArray<InventoryInputGroup>([]),
    outputs: new FormArray<OutputGroup>([this.createOutput()]),
    controls: new FormArray<ControlGroup>([]),
  });

  get intermediateInputs(): FormArray<IntermediateInputGroup> {
    return this.form.controls.intermediateInputs;
  }

  get sourceLotInputs(): FormArray<SourceLotInputGroup> {
    return this.form.controls.sourceLotInputs;
  }

  get inventoryInputs(): FormArray<InventoryInputGroup> {
    return this.form.controls.inventoryInputs;
  }

  get outputs(): FormArray<OutputGroup> {
    return this.form.controls.outputs;
  }

  get controls(): FormArray<ControlGroup> {
    return this.form.controls.controls;
  }

  async ngOnInit(): Promise<void> {
    await this.load();
    this.form.controls.performedBy.setValue(
      this.auth.profile()?.display_name || this.auth.user()?.email || '',
    );
    const firstOutput = this.outputs.at(0);
    firstOutput.controls['uomId'].setValue(this.unitId('kg'));
    firstOutput.controls['locationId'].setValue(this.locationId('PRODUCTION'));
    this.applyTemplate(PROCESS_TEMPLATES[0].key);
  }

  toggleForm(): void {
    this.showForm.set(!this.showForm());
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  applyTemplate(key: string): void {
    const template = PROCESS_TEMPLATES.find((candidate) => candidate.key === key);
    if (!template) return;
    this.selectedTemplate.set(template);
    this.form.controls.templateKey.setValue(key);
    this.controls.clear();
    for (const control of template.controls) this.controls.push(this.createControl(control));
  }

  addIntermediateInput(): void {
    this.intermediateInputs.push(this.createIntermediateInput());
  }

  addSourceLotInput(): void {
    this.sourceLotInputs.push(this.createSourceLotInput());
  }

  addInventoryInput(): void {
    this.inventoryInputs.push(this.createInventoryInput());
  }

  addOutput(): void {
    this.outputs.push(this.createOutput());
  }

  addControl(): void {
    this.controls.push(this.createControl());
  }

  removeRow(array: { removeAt(index: number): void }, index: number): void {
    array.removeAt(index);
  }

  selectIntermediate(index: number, id: string): void {
    const lot = this.lots().find((candidate) => candidate.id === id);
    if (lot) this.intermediateInputs.at(index).controls['quantity'].setValue(lot.current_quantity);
  }

  selectSourceLot(index: number, id: string): void {
    const lot = this.sourceLots().find((candidate) => candidate.id === id);
    if (lot) this.sourceLotInputs.at(index).controls['quantity'].setValue(lot.available_quantity);
  }

  selectInventory(index: number, key: string): void {
    const balance = this.inventoryBalance(key);
    if (balance)
      this.inventoryInputs.at(index).controls['quantity'].setValue(balance.current_quantity);
  }

  inventoryKey(balance: TransformationInventoryBalance): string {
    return balance.inventory_lot_id + '|' + balance.storage_location_id;
  }

  inventoryBalance(key: string): TransformationInventoryBalance | undefined {
    return this.inventoryBalances().find((balance) => this.inventoryKey(balance) === key);
  }

  recipeLabel(version: RecipeVersionOption): string {
    return `${version.recipes?.products?.name ?? 'Product'} · ${version.recipes?.name ?? 'Recipe'} v${version.version_number}`;
  }

  toggleHistory(id: string): void {
    this.expandedHistoryId.set(this.expandedHistoryId() === id ? null : id);
  }

  totalInputs(record: TransformationHistory): number {
    return (
      record.transformation_inputs.length +
      record.transformation_source_lot_inputs.length +
      record.transformation_inventory_inputs.length
    );
  }

  async record(): Promise<void> {
    if (this.form.invalid || this.saving()) {
      this.form.markAllAsTouched();
      return;
    }
    const values = this.form.getRawValue();
    const intermediateInputs = values.intermediateInputs.filter((input) => input.lotId);
    const sourceInputs = values.sourceLotInputs.filter((input) => input.lotId);
    const inventoryInputs = values.inventoryInputs.filter((input) => input.balanceKey);
    if (intermediateInputs.length + sourceInputs.length + inventoryInputs.length === 0) {
      this.errorMessage.set('Add at least one intermediate, milk/cream, or inventory input.');
      return;
    }
    if (
      [...intermediateInputs, ...sourceInputs, ...inventoryInputs].some(
        (input) => input.quantity === null || Number(input.quantity) <= 0,
      )
    ) {
      this.errorMessage.set('Every selected input lot requires a positive actual quantity.');
      return;
    }
    if (
      values.controls.some(
        (control) => control.numericValue === null && control.textValue.trim().length === 0,
      )
    ) {
      this.errorMessage.set('Enter an actual numeric or text result for every process control.');
      return;
    }
    if (this.hasDuplicateInputs(intermediateInputs, sourceInputs, inventoryInputs)) {
      this.errorMessage.set('The same stock lot cannot be entered twice in one input section.');
      return;
    }
    const template = this.selectedTemplate();
    this.saving.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.transformationService.record({
        type: template.type,
        processTemplate: template.name,
        occurredAt: values.occurredAt,
        performedBy: values.performedBy,
        recipeVersionId: this.optional(values.recipeVersionId),
        intermediateInputs: intermediateInputs.map((input) => ({
          intermediate_lot_id: input.lotId,
          quantity: Number(input.quantity),
          standard_quantity: this.optionalNumber(input.standardQuantity),
        })),
        sourceLotInputs: sourceInputs.map((input) => ({
          source_lot_id: input.lotId,
          quantity: Number(input.quantity),
        })),
        inventoryInputs: inventoryInputs.map((input) => {
          const balance = this.inventoryBalance(input.balanceKey)!;
          return {
            inventory_lot_id: balance.inventory_lot_id,
            source_location_id: balance.storage_location_id,
            quantity: Number(input.quantity),
            standard_quantity: this.optionalNumber(input.standardQuantity),
          };
        }),
        outputs: values.outputs.map((output) => ({
          product_id: output.productId,
          quantity: Number(output.quantity),
          uom_id: output.uomId,
          destination_location_id: output.locationId,
          kind: output.kind,
          label: output.label,
        })),
        controls: values.controls.map((control) => ({
          code: control.code,
          label: control.label,
          numeric_value: this.optionalNumber(control.numericValue),
          text_value: this.optional(control.textValue),
          uom_label: this.optional(control.uomLabel),
          target_value: this.optionalNumber(control.targetValue),
          min_value: this.optionalNumber(control.minValue),
          max_value: this.optionalNumber(control.maxValue),
        })),
        notes: this.optional(values.notes),
      });
      this.successMessage.set(`${template.name} recorded and output lots created.`);
      this.resetTransactionForm();
      this.showForm.set(false);
      await this.load(false);
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to record this transformation.',
      );
    } finally {
      this.saving.set(false);
    }
  }

  private async load(showLoader = true): Promise<void> {
    if (showLoader) this.loading.set(true);
    try {
      const data = await this.transformationService.load();
      this.lots.set(data.lots);
      this.sourceLots.set(data.sourceLots);
      this.inventoryBalances.set(data.inventoryBalances);
      this.products.set(data.products);
      this.units.set(data.units);
      this.locations.set(data.locations);
      this.recipeVersions.set(data.recipeVersions);
      this.history.set(data.history);
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to load product transformations.',
      );
    } finally {
      this.loading.set(false);
    }
  }

  private resetTransactionForm(): void {
    const operator = this.form.controls.performedBy.value;
    this.form.reset({
      templateKey: this.selectedTemplate().key,
      occurredAt: this.localDateTime(),
      performedBy: operator,
      recipeVersionId: '',
      notes: '',
    });
    this.intermediateInputs.clear();
    this.intermediateInputs.push(this.createIntermediateInput());
    this.sourceLotInputs.clear();
    this.inventoryInputs.clear();
    this.outputs.clear();
    this.outputs.push(this.createOutput());
    this.applyTemplate(this.selectedTemplate().key);
  }

  private createIntermediateInput(): IntermediateInputGroup {
    return new FormGroup({
      lotId: new FormControl('', { nonNullable: true }),
      quantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
      standardQuantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
    });
  }

  private createSourceLotInput(): SourceLotInputGroup {
    return new FormGroup({
      lotId: new FormControl('', { nonNullable: true }),
      quantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
    });
  }

  private createInventoryInput(): InventoryInputGroup {
    return new FormGroup({
      balanceKey: new FormControl('', { nonNullable: true }),
      quantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
      standardQuantity: new FormControl<number | null>(null, [Validators.min(0.001)]),
    });
  }

  private createOutput(): OutputGroup {
    return new FormGroup({
      productId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
      quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
      uomId: new FormControl(this.unitId('kg'), {
        nonNullable: true,
        validators: [Validators.required],
      }),
      locationId: new FormControl(this.locationId('PRODUCTION'), {
        nonNullable: true,
        validators: [Validators.required],
      }),
      kind: new FormControl('primary', { nonNullable: true }),
      label: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    });
  }

  private createControl(preset?: ProcessControlPreset): ControlGroup {
    return new FormGroup({
      code: new FormControl(preset?.code ?? '', {
        nonNullable: true,
        validators: [Validators.required],
      }),
      label: new FormControl(preset?.label ?? '', {
        nonNullable: true,
        validators: [Validators.required],
      }),
      numericValue: new FormControl<number | null>(null),
      textValue: new FormControl('', { nonNullable: true }),
      uomLabel: new FormControl(preset?.uomLabel ?? '', { nonNullable: true }),
      targetValue: new FormControl<number | null>(preset?.targetValue ?? null),
      minValue: new FormControl<number | null>(preset?.minValue ?? null),
      maxValue: new FormControl<number | null>(preset?.maxValue ?? null),
    });
  }

  private hasDuplicateInputs(
    intermediate: Array<{ lotId: string }>,
    source: Array<{ lotId: string }>,
    inventory: Array<{ balanceKey: string }>,
  ): boolean {
    return (
      new Set(intermediate.map((row) => row.lotId)).size !== intermediate.length ||
      new Set(source.map((row) => row.lotId)).size !== source.length ||
      new Set(inventory.map((row) => row.balanceKey)).size !== inventory.length
    );
  }

  private optional(value: string): string | null {
    return value.trim() || null;
  }

  private optionalNumber(value: number | null): number | null {
    return value === null || value === undefined || value === ('' as unknown as number)
      ? null
      : Number(value);
  }

  private unitId(code: string): string {
    return this.units().find((unit) => unit.code === code)?.id ?? '';
  }

  private locationId(code: string): string {
    return this.locations().find((location) => location.code === code)?.id ?? '';
  }

  private localDateTime(): string {
    const now = new Date();
    now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
    return now.toISOString().slice(0, 16);
  }
}
