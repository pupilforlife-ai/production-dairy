import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnDestroy, OnInit, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  CUT_FORMAT_OPTIONS,
  PANEER_STAGE_OPTIONS,
  formatRemainingTime,
  getStageTimer,
  paneerStageLabel,
  receivedDateBatchCode,
  summarizeBlockWeights,
  summarizeCreamBuckets,
  summarizeIngredientIssues,
  type BoardSku,
  type BlockWeightSummary,
  type PaneerCutFormat,
  type PaneerProcessStage,
  type PressedPaneerBlock,
  type ProductOption,
  type ProductionBatchSummary,
  type ProductionCreamBucket,
  type ProductionHandlingEvent,
  type ProductionIngredientIssue,
  type RoundPackingEntry,
  type ShiftSummary,
  type SourceLotOption,
} from './production-board.models';
import { ProductionBoardService, type EditableRoundField } from './production-board.service';

@Component({
  selector: 'app-production-board-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './production-board.page.html',
})
export class ProductionBoardPage implements OnInit, OnDestroy {
  private readonly boardService = inject(ProductionBoardService);
  private timerInterval: ReturnType<typeof setInterval> | undefined;

  readonly sourceLots = signal<SourceLotOption[]>([]);
  readonly products = signal<ProductOption[]>([]);
  readonly shifts = signal<ShiftSummary[]>([]);
  readonly batches = signal<ProductionBatchSummary[]>([]);
  readonly skus = signal<BoardSku[]>([]);
  readonly packingEntries = signal<RoundPackingEntry[]>([]);
  readonly blocks = signal<PressedPaneerBlock[]>([]);
  readonly handlingEvents = signal<ProductionHandlingEvent[]>([]);
  readonly creamBuckets = signal<ProductionCreamBucket[]>([]);
  readonly ingredientIssues = signal<ProductionIngredientIssue[]>([]);
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly updatingCell = signal<string | null>(null);
  readonly updatingBlock = signal<string | null>(null);
  readonly updatingCream = signal<string | null>(null);
  readonly retryingIngredients = signal<string | null>(null);
  readonly addingRoundShiftId = signal<string | null>(null);
  readonly showShiftForm = signal(false);
  readonly packingBatchId = signal<string | null>(null);
  readonly blockPanelBatchId = signal<string | null>(null);
  readonly creamPanelBatchId = signal<string | null>(null);
  readonly ingredientPanelBatchId = signal<string | null>(null);
  readonly historyBatchId = signal<string | null>(null);
  readonly collapsedShiftIds = signal<Set<string>>(new Set());
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly now = signal(new Date());

  readonly stages = PANEER_STAGE_OPTIONS;
  readonly cutFormats = CUT_FORMAT_OPTIONS;
  readonly stageLabel = paneerStageLabel;
  readonly remainingLabel = formatRemainingTime;

  readonly shiftForm = new FormGroup({
    sourceLotId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    shiftNumber: new FormControl<number | null>(null, [Validators.required, Validators.min(1)]),
    startedAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    teamMembers: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    teamNotes: new FormControl('', { nonNullable: true }),
  });

  readonly packingForm = new FormGroup({
    skuId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    cases: new FormControl(0, { nonNullable: true, validators: [Validators.min(0)] }),
    loosePackets: new FormControl(0, { nonNullable: true, validators: [Validators.min(0)] }),
  });

  readonly creamForm = new FormGroup({
    weightKg: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
  });

  async ngOnInit(): Promise<void> {
    this.timerInterval = setInterval(() => this.now.set(new Date()), 30_000);
    await this.load();
  }

  ngOnDestroy(): void {
    if (this.timerInterval) clearInterval(this.timerInterval);
  }

  async createShift(): Promise<void> {
    if (this.shiftForm.invalid || this.saving()) {
      this.shiftForm.markAllAsTouched();
      return;
    }
    const values = this.shiftForm.getRawValue();
    if (values.shiftNumber === null) return;
    const teamMembers = values.teamMembers
      .split(/[,\n]/)
      .map((name) => name.trim())
      .filter(Boolean);
    if (!teamMembers.length) {
      this.errorMessage.set('Enter at least one team member.');
      return;
    }

    await this.runSave(async () => {
      await this.boardService.createShift({
        sourceLotId: values.sourceLotId,
        shiftNumber: values.shiftNumber!,
        startedAt: values.startedAt,
        teamMembers,
        teamNotes: this.optional(values.teamNotes),
      });
      this.successMessage.set(`Shift ${values.shiftNumber} created.`);
      this.shiftForm.reset({
        sourceLotId: values.sourceLotId,
        shiftNumber: null,
        startedAt: this.localDateTime(),
        teamMembers: '',
        teamNotes: '',
      });
      this.showShiftForm.set(false);
      await this.load(false);
    });
  }

  async addRound(shift: ShiftSummary): Promise<void> {
    if (shift.status !== 'open' || this.addingRoundShiftId()) return;
    this.addingRoundShiftId.set(shift.id);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.boardService.addRound(shift.id);
      await this.load(false);
      const newest = this.roundsForShift(shift.id).at(-1);
      this.successMessage.set(
        `Round ${newest?.round_number ?? ''} added to Shift ${shift.shift_number}.`,
      );
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to add a production round.'));
    } finally {
      this.addingRoundShiftId.set(null);
    }
  }

  async updateRoundCell(
    batch: ProductionBatchSummary,
    field: EditableRoundField,
    value: string | number | null,
  ): Promise<void> {
    if (batch.locked_at || this.isUnchanged(batch, field, value)) return;
    const cellKey = `${batch.id}:${field}`;
    if (this.updatingCell()) return;
    this.updatingCell.set(cellKey);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      const saved = await this.boardService.updateCell(batch.id, field, value);
      const stageChanged = saved.process_stage && saved.process_stage !== batch.process_stage;
      const selectedProduct =
        field === 'type'
          ? (this.products().find((product) => product.variant === value) ?? batch.products)
          : batch.products;
      this.batches.update((items) =>
        items.map((item) => {
          if (item.id !== batch.id) return item;
          const updated = {
            ...item,
            ...saved,
            products: selectedProduct,
          } as ProductionBatchSummary;
          if (stageChanged && saved.process_stage_changed_at) {
            updated.production_batch_stage_events = [
              {
                id: `pending-${saved.process_stage_changed_at}`,
                stage: saved.process_stage as PaneerProcessStage,
                changed_at: saved.process_stage_changed_at,
              },
              ...item.production_batch_stage_events,
            ];
          }
          return updated;
        }),
      );
      this.successMessage.set(
        `Shift ${batch.production_shifts?.shift_number}, Round ${batch.round_number} updated.`,
      );
      if (field === 'type' || field === 'process_stage' || field === 'milk_quantity') {
        await this.load(false);
      }
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to update this production-board cell.'));
      await this.load(false);
    } finally {
      this.updatingCell.set(null);
    }
  }

  async updateBlockCount(batch: ProductionBatchSummary, value: string): Promise<void> {
    if (batch.locked_at || this.updatingBlock()) return;
    const count = Number(value);
    if (!Number.isInteger(count) || count <= 0) {
      this.errorMessage.set('Number of blocks must be a whole number greater than zero.');
      await this.load(false);
      return;
    }
    if (batch.pressed_block_count === count) {
      this.blockPanelBatchId.set(batch.id);
      return;
    }

    this.updatingBlock.set(`${batch.id}:count`);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.boardService.setBlockCount(batch.id, count);
      await this.load(false);
      this.blockPanelBatchId.set(batch.id);
      this.successMessage.set(
        `${count} block weight fields created for Round ${batch.round_number}.`,
      );
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to save the number of blocks.'));
      await this.load(false);
    } finally {
      this.updatingBlock.set(null);
    }
  }

  async updateBlockWeight(
    batch: ProductionBatchSummary,
    block: PressedPaneerBlock,
    value: string,
  ): Promise<void> {
    if (batch.locked_at || this.updatingBlock()) return;
    const weight = Number(value);
    if (!Number.isFinite(weight) || weight <= 0) {
      this.errorMessage.set(`Enter a valid weight for Block ${block.block_number}.`);
      return;
    }
    if (Number(block.weight_kg) === weight) return;

    this.updatingBlock.set(block.id);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      const saved = await this.boardService.setBlockWeight(batch.id, block.block_number, weight);
      this.blocks.update((items) => items.map((item) => (item.id === block.id ? saved : item)));
      this.successMessage.set(
        weight > 13
          ? `Block ${block.block_number} saved and recorded as an above-capacity anomaly.`
          : `Block ${block.block_number} weight saved.`,
      );
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to save the block weight.'));
    } finally {
      this.updatingBlock.set(null);
    }
  }

  openPacking(batch: ProductionBatchSummary): void {
    if (!batch.cut_completed_at || batch.cut_format === 'spp') return;
    this.packingBatchId.set(this.packingBatchId() === batch.id ? null : batch.id);
    const firstSku = this.compatibleSkus(batch)[0];
    this.packingForm.reset({ skuId: firstSku?.id ?? '', cases: 0, loosePackets: 0 });
  }

  async savePacking(batch: ProductionBatchSummary): Promise<void> {
    if (this.packingForm.invalid || this.saving()) {
      this.packingForm.markAllAsTouched();
      return;
    }
    const values = this.packingForm.getRawValue();
    if (values.cases + values.loosePackets <= 0) {
      this.errorMessage.set('Enter at least one case or loose packet.');
      return;
    }
    await this.runSave(async () => {
      await this.boardService.addPackingEntry(
        batch.id,
        values.skuId,
        values.cases,
        values.loosePackets,
      );
      this.successMessage.set(
        `Packing added to Shift ${batch.production_shifts?.shift_number}, Round ${batch.round_number}.`,
      );
      this.packingBatchId.set(null);
      await this.load(false);
    });
  }

  openCreamPanel(batch: ProductionBatchSummary): void {
    this.creamPanelBatchId.set(this.creamPanelBatchId() === batch.id ? null : batch.id);
    this.creamForm.reset({ weightKg: null });
  }

  async addCreamBucket(batch: ProductionBatchSummary): Promise<void> {
    if (this.creamForm.invalid || this.updatingCream()) {
      this.creamForm.markAllAsTouched();
      return;
    }
    const weight = this.creamForm.getRawValue().weightKg;
    if (weight === null) return;

    this.updatingCream.set(`${batch.id}:new`);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.boardService.addCreamBucket(batch.id, weight);
      await this.load(false);
      this.creamForm.reset({ weightKg: null });
      const newest = this.creamBucketsFor(batch.id).at(-1);
      this.successMessage.set(
        `Cream Bucket ${newest?.bucket_number ?? ''} recorded at ${weight} kg in the Dairy Container.`,
      );
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to record the cream bucket.'));
    } finally {
      this.updatingCream.set(null);
    }
  }

  async updateCreamBucket(bucket: ProductionCreamBucket, value: string): Promise<void> {
    if (this.updatingCream()) return;
    const weight = Number(value);
    if (!Number.isFinite(weight) || weight <= 0) {
      this.errorMessage.set(`Enter a valid weight for Cream Bucket ${bucket.bucket_number}.`);
      return;
    }
    if (Number(bucket.weight_kg) === weight) return;

    this.updatingCream.set(bucket.id);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.boardService.updateCreamBucketWeight(bucket.id, weight);
      this.creamBuckets.update((items) =>
        items.map((item) => (item.id === bucket.id ? { ...item, weight_kg: weight } : item)),
      );
      this.successMessage.set(`Cream Bucket ${bucket.bucket_number} corrected to ${weight} kg.`);
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to correct the cream bucket weight.'));
      await this.load(false);
    } finally {
      this.updatingCream.set(null);
    }
  }

  roundsForShift(shiftId: string): ProductionBatchSummary[] {
    return this.batches()
      .filter((batch) => batch.shift_id === shiftId)
      .sort((left, right) => left.round_number - right.round_number);
  }

  packingFor(batchId: string): RoundPackingEntry[] {
    return this.packingEntries().filter((entry) => entry.production_batch_id === batchId);
  }

  blocksFor(batchId: string): PressedPaneerBlock[] {
    return this.blocks()
      .filter((block) => block.production_batch_id === batchId)
      .sort((left, right) => left.block_number - right.block_number);
  }

  creamBucketsFor(batchId: string): ProductionCreamBucket[] {
    return this.creamBuckets()
      .filter((bucket) => bucket.production_batch_id === batchId)
      .sort((left, right) => left.bucket_number - right.bucket_number);
  }

  creamSummary(batchId: string) {
    return summarizeCreamBuckets(this.creamBucketsFor(batchId));
  }

  hasCream(batchId: string): boolean {
    return this.creamBuckets().some((bucket) => bucket.production_batch_id === batchId);
  }

  ingredientIssuesFor(batchId: string): ProductionIngredientIssue[] {
    return this.ingredientIssues().filter((issue) => issue.production_batch_id === batchId);
  }

  ingredientSummary(batchId: string) {
    return summarizeIngredientIssues(this.ingredientIssuesFor(batchId));
  }

  ingredientsDue(batch: ProductionBatchSummary): boolean {
    return batch.process_stage !== 'vat_1';
  }

  hasIngredientProcessing(batchId: string): boolean {
    return this.ingredientIssues().some((issue) => issue.production_batch_id === batchId);
  }

  toggleIngredientPanel(batchId: string): void {
    this.ingredientPanelBatchId.set(this.ingredientPanelBatchId() === batchId ? null : batchId);
  }

  async retryIngredientShortages(batch: ProductionBatchSummary): Promise<void> {
    if (this.retryingIngredients()) return;
    this.retryingIngredients.set(batch.id);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.boardService.retryIngredientShortages(batch.id);
      await this.load(false);
      const summary = this.ingredientSummary(batch.id);
      this.successMessage.set(
        summary.hasShortage
          ? `Ingredient shortage remains for Round ${batch.round_number}.`
          : `Ingredient issues are complete for Round ${batch.round_number}.`,
      );
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to retry ingredient shortages.'));
    } finally {
      this.retryingIngredients.set(null);
    }
  }

  blockSummary(batch: ProductionBatchSummary): BlockWeightSummary {
    return summarizeBlockWeights(batch.pressed_block_count, this.blocksFor(batch.id));
  }

  blocksComplete(batch: ProductionBatchSummary): boolean {
    return this.blockSummary(batch).complete;
  }

  toggleBlockPanel(batch: ProductionBatchSummary): void {
    if (!batch.pressed_block_count) return;
    this.blockPanelBatchId.set(this.blockPanelBatchId() === batch.id ? null : batch.id);
  }

  latestClingWrappedEvent(batchId: string): ProductionHandlingEvent | null {
    return (
      this.handlingEvents()
        .filter((event) => event.production_batch_id === batchId)
        .sort(
          (left, right) =>
            new Date(right.recorded_at).getTime() - new Date(left.recorded_at).getTime(),
        )[0] ?? null
    );
  }

  compatibleSkus(batch: ProductionBatchSummary): BoardSku[] {
    return this.skus().filter((sku) => sku.product_id === batch.product_id);
  }

  timerFor(batch: ProductionBatchSummary) {
    return getStageTimer(batch.process_stage, batch.process_stage_changed_at, this.now());
  }

  batchCode(shift: ShiftSummary): string {
    return shift.source_lots?.received_at
      ? receivedDateBatchCode(shift.source_lots.received_at)
      : '—';
  }

  trayReference(shift: ShiftSummary, batch: ProductionBatchSummary): string {
    return `S${shift.shift_number} / R${batch.round_number}`;
  }

  isShiftCollapsed(shiftId: string): boolean {
    return this.collapsedShiftIds().has(shiftId);
  }

  toggleShift(shiftId: string): void {
    this.collapsedShiftIds.update((collapsedIds) => {
      const next = new Set(collapsedIds);
      if (next.has(shiftId)) next.delete(shiftId);
      else next.add(shiftId);
      return next;
    });
  }

  lotRemaining(lot: SourceLotOption): number {
    const consumed = this.batches()
      .filter((batch) => batch.parent_source_lot_id === lot.id && batch.status !== 'cancelled')
      .reduce((total, batch) => total + Number(batch.actual_primary_input_quantity || 0), 0);
    return Number(lot.received_quantity) - consumed;
  }

  hasPacking(batch: ProductionBatchSummary): boolean {
    return this.packingEntries().some((entry) => entry.production_batch_id === batch.id);
  }

  cellBusy(batch: ProductionBatchSummary, field: EditableRoundField): boolean {
    return this.updatingCell() === `${batch.id}:${field}`;
  }

  toggleHistory(batchId: string): void {
    this.historyBatchId.set(this.historyBatchId() === batchId ? null : batchId);
  }

  private isUnchanged(
    batch: ProductionBatchSummary,
    field: EditableRoundField,
    value: string | number | null,
  ): boolean {
    if (field === 'milk_quantity') return batch.actual_primary_input_quantity === Number(value);
    if (field === 'type') return batch.products?.variant === value;
    if (field === 'milk_temperature') {
      const normalized = value === '' || value === null ? null : Number(value);
      return batch.milk_start_temperature_c === normalized;
    }
    if (field === 'process_stage') return batch.process_stage === value;
    if (field === 'cut_by') return (batch.cut_by ?? '') === String(value ?? '').trim();
    return (batch.cut_format ?? '') === value;
  }

  private async load(showLoading = true): Promise<void> {
    if (showLoading) this.loading.set(true);
    try {
      const data = await this.boardService.load();
      this.sourceLots.set(data.sourceLots);
      this.products.set(data.products);
      this.shifts.set(data.shifts);
      this.batches.set(data.batches);
      this.skus.set(data.skus);
      this.packingEntries.set(data.packingEntries);
      this.blocks.set(data.blocks);
      this.handlingEvents.set(data.handlingEvents);
      this.creamBuckets.set(data.creamBuckets);
      this.ingredientIssues.set(data.ingredientIssues);
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to load the production board.'));
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
      this.errorMessage.set(this.errorText(error, 'Unable to save the production record.'));
    } finally {
      this.saving.set(false);
    }
  }

  private optional(value: string): string | null {
    return value.trim() || null;
  }

  private errorText(error: unknown, fallback: string): string {
    if (error && typeof error === 'object' && 'message' in error) return String(error.message);
    return fallback;
  }

  private localDateTime(): string {
    const date = new Date();
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
    return local.toISOString().slice(0, 16);
  }
}
