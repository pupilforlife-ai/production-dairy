import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  balanceKey,
  type InventoryBalance,
  type InventoryItem,
  type InventoryItemType,
  type InventoryLocation,
  type InventoryMovementSummary,
  type InventoryReference,
  type InventoryUsageSummary,
  type InventoryUnit,
} from './inventory.models';
import { InventoryService } from './inventory.service';

type InventoryAction = 'item' | 'receive' | 'transfer' | 'consume' | 'adjust' | null;
type ConsumptionReferenceType = 'none' | 'production' | 'packing';

@Component({
  selector: 'app-inventory-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './inventory.page.html',
})
export class InventoryPage implements OnInit {
  private readonly inventoryService = inject(InventoryService);
  readonly auth = inject(AuthService);
  readonly items = signal<InventoryItem[]>([]);
  readonly balances = signal<InventoryBalance[]>([]);
  readonly locations = signal<InventoryLocation[]>([]);
  readonly units = signal<InventoryUnit[]>([]);
  readonly productionReferences = signal<InventoryReference[]>([]);
  readonly packingReferences = signal<InventoryReference[]>([]);
  readonly movements = signal<InventoryMovementSummary[]>([]);
  readonly usageSummaries = signal<InventoryUsageSummary[]>([]);
  readonly activeAction = signal<InventoryAction>(null);
  readonly consumptionReferenceType = signal<ConsumptionReferenceType>('none');
  readonly selectedBalanceKey = signal<string | null>(null);
  readonly inlineMoveKey = signal<string | null>(null);
  readonly itemTypeFilter = signal('');
  readonly locationFilter = signal('');
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly keyForBalance = balanceKey;

  readonly filteredBalances = computed(() =>
    this.balances().filter(
      (balance) =>
        (!this.itemTypeFilter() || balance.item_type === this.itemTypeFilter()) &&
        (!this.locationFilter() || balance.storage_location_id === this.locationFilter()),
    ),
  );
  readonly ingredientCount = computed(
    () => this.items().filter((item) => item.item_type === 'ingredient').length,
  );
  readonly packagingCount = computed(
    () => this.items().filter((item) => item.item_type === 'packaging').length,
  );
  readonly representedLots = computed(
    () => new Set(this.balances().map((balance) => balance.inventory_lot_id)).size,
  );
  readonly selectedBalance = computed(() => {
    const key = this.selectedBalanceKey();
    return key ? this.findBalance(key) : null;
  });
  readonly selectedMovements = computed(() => {
    const balance = this.selectedBalance();
    if (!balance) return [];
    return this.movements().filter(
      (movement) =>
        movement.inventory_items?.code === balance.item_code &&
        movement.inventory_lots?.lot_code === balance.lot_code,
    );
  });
  readonly selectedUsageSummaries = computed(() => {
    const balance = this.selectedBalance();
    if (!balance) return [];
    return this.usageSummaries().filter(
      (summary) => summary.inventory_item_id === balance.inventory_item_id,
    );
  });

  readonly itemForm = new FormGroup({
    itemType: new FormControl<InventoryItemType>('packaging', { nonNullable: true }),
    code: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    uomId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
  });

  readonly receiveForm = new FormGroup({
    itemId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    lotCode: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
    destinationLocationId: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required],
    }),
    receivedAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    expiryDate: new FormControl('', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
  });

  readonly transferForm = new FormGroup({
    balanceKey: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
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

  readonly consumeForm = new FormGroup({
    balanceKey: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
    referenceId: new FormControl('', { nonNullable: true }),
    occurredAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    notes: new FormControl('', { nonNullable: true }),
  });

  readonly adjustForm = new FormGroup({
    balanceKey: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    countedQuantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0)]),
    reason: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    occurredAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
  });

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  toggleAction(action: Exclude<InventoryAction, null>): void {
    this.activeAction.set(this.activeAction() === action ? null : action);
    this.inlineMoveKey.set(null);
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  selectTransferBalance(key: string): void {
    const balance = this.findBalance(key);
    if (balance) this.transferForm.controls.quantity.setValue(Number(balance.current_quantity));
  }

  selectConsumeBalance(key: string): void {
    const balance = this.findBalance(key);
    if (balance) this.consumeForm.controls.quantity.setValue(Number(balance.current_quantity));
  }

  startMove(balance: InventoryBalance): void {
    const key = balanceKey(balance);
    this.selectedBalanceKey.set(key);
    this.inlineMoveKey.set(this.inlineMoveKey() === key ? null : key);
    this.activeAction.set(null);
    this.transferForm.reset({
      balanceKey: key,
      quantity: Number(balance.current_quantity),
      destinationLocationId: this.defaultMoveDestination(balance),
      occurredAt: this.localDateTime(),
      notes: '',
    });
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  cancelMove(): void {
    this.inlineMoveKey.set(null);
  }

  selectBalanceForHistory(balance: InventoryBalance): void {
    this.selectedBalanceKey.set(balanceKey(balance));
  }

  startCount(balance: InventoryBalance): void {
    if (!this.auth.hasRole('owner')) return;
    const key = balanceKey(balance);
    this.selectedBalanceKey.set(key);
    this.activeAction.set('adjust');
    this.adjustForm.reset({
      balanceKey: key,
      countedQuantity: Number(balance.current_quantity),
      reason: '',
      occurredAt: this.localDateTime(),
    });
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  setConsumptionReference(type: string): void {
    this.consumptionReferenceType.set(type as ConsumptionReferenceType);
    this.consumeForm.controls.referenceId.setValue('');
  }

  consumptionReferences(): InventoryReference[] {
    if (this.consumptionReferenceType() === 'production') return this.productionReferences();
    if (this.consumptionReferenceType() === 'packing') return this.packingReferences();
    return [];
  }

  async createItem(): Promise<void> {
    if (this.itemForm.invalid || this.saving()) {
      this.itemForm.markAllAsTouched();
      return;
    }
    const values = this.itemForm.getRawValue();
    await this.runSave(async () => {
      await this.inventoryService.createItem({
        itemType: values.itemType,
        code: values.code,
        name: values.name,
        uomId: values.uomId,
      });
      this.successMessage.set(values.name.trim() + ' added to inventory master data.');
      this.itemForm.reset({ itemType: 'packaging', code: '', name: '', uomId: '' });
      this.activeAction.set(null);
      await this.load(false);
    });
  }

  async receive(): Promise<void> {
    if (this.receiveForm.invalid || this.saving()) {
      this.receiveForm.markAllAsTouched();
      return;
    }
    const values = this.receiveForm.getRawValue();
    if (values.quantity === null) return;
    await this.runSave(async () => {
      await this.inventoryService.receive({
        itemId: values.itemId,
        lotCode: values.lotCode,
        quantity: values.quantity!,
        destinationLocationId: values.destinationLocationId,
        receivedAt: values.receivedAt,
        expiryDate: this.optional(values.expiryDate),
        notes: this.optional(values.notes),
      });
      this.successMessage.set('Inventory receipt recorded.');
      this.receiveForm.reset({
        itemId: values.itemId,
        lotCode: '',
        quantity: null,
        destinationLocationId: this.locationId('BULK_INGREDIENT'),
        receivedAt: this.localDateTime(),
        expiryDate: '',
        notes: '',
      });
      this.activeAction.set(null);
      await this.load(false);
    });
  }

  async transfer(): Promise<void> {
    if (this.transferForm.invalid || this.saving()) {
      this.transferForm.markAllAsTouched();
      return;
    }
    const values = this.transferForm.getRawValue();
    const balance = this.findBalance(values.balanceKey);
    if (!balance || values.quantity === null) return;
    if (values.destinationLocationId === balance.storage_location_id) {
      this.errorMessage.set('Choose a different destination location.');
      return;
    }
    await this.runSave(async () => {
      await this.inventoryService.transfer({
        lotId: balance.inventory_lot_id,
        sourceLocationId: balance.storage_location_id,
        destinationLocationId: values.destinationLocationId,
        quantity: values.quantity!,
        occurredAt: values.occurredAt,
        notes: this.optional(values.notes),
      });
      this.successMessage.set('Inventory transfer recorded.');
      this.activeAction.set(null);
      this.inlineMoveKey.set(null);
      await this.load(false);
    });
  }

  async consume(): Promise<void> {
    if (this.consumeForm.invalid || this.saving()) {
      this.consumeForm.markAllAsTouched();
      return;
    }
    const values = this.consumeForm.getRawValue();
    const balance = this.findBalance(values.balanceKey);
    const referenceType = this.consumptionReferenceType();
    if (!balance || values.quantity === null) return;
    if (referenceType !== 'none' && !values.referenceId) {
      this.errorMessage.set('Select the production or packing reference.');
      return;
    }
    await this.runSave(async () => {
      await this.inventoryService.consume({
        lotId: balance.inventory_lot_id,
        sourceLocationId: balance.storage_location_id,
        quantity: values.quantity!,
        productionBatchId: referenceType === 'production' ? values.referenceId : null,
        packingRunId: referenceType === 'packing' ? values.referenceId : null,
        occurredAt: values.occurredAt,
        notes: this.optional(values.notes),
      });
      this.successMessage.set('Inventory consumption recorded.');
      this.activeAction.set(null);
      await this.load(false);
    });
  }

  async adjust(): Promise<void> {
    if (this.adjustForm.invalid || this.saving()) {
      this.adjustForm.markAllAsTouched();
      return;
    }
    const values = this.adjustForm.getRawValue();
    const balance = this.findBalance(values.balanceKey);
    if (!balance || values.countedQuantity === null) return;
    const adjustmentQuantity = values.countedQuantity - Number(balance.current_quantity);
    if (adjustmentQuantity === 0) {
      this.errorMessage.set('Counted quantity is unchanged.');
      return;
    }
    await this.runSave(async () => {
      await this.inventoryService.adjust({
        lotId: balance.inventory_lot_id,
        locationId: balance.storage_location_id,
        adjustmentQuantity,
        reason: values.reason,
        occurredAt: values.occurredAt,
      });
      this.successMessage.set('Owner stocktake adjustment recorded in the audit ledger.');
      this.activeAction.set(null);
      await this.load(false);
    });
  }

  private async load(showLoading = true): Promise<void> {
    if (showLoading) this.loading.set(true);
    try {
      const data = await this.inventoryService.load();
      this.items.set(data.items);
      this.balances.set(data.balances);
      this.locations.set(data.locations);
      this.units.set(data.units);
      this.productionReferences.set(data.productionReferences);
      this.packingReferences.set(data.packingReferences);
      this.movements.set(data.movements);
      this.usageSummaries.set(data.usageSummaries);
      if (!this.selectedBalanceKey() && data.balances.length > 0) {
        this.selectedBalanceKey.set(balanceKey(data.balances[0]));
      }
      if (!this.receiveForm.controls.destinationLocationId.value) {
        this.receiveForm.controls.destinationLocationId.setValue(
          this.locationId('BULK_INGREDIENT'),
        );
      }
      if (!this.transferForm.controls.destinationLocationId.value) {
        this.transferForm.controls.destinationLocationId.setValue(
          this.locationId('INTERMEDIATE_INGREDIENT'),
        );
      }
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to load inventory.'));
    } finally {
      if (showLoading) this.loading.set(false);
    }
  }

  private findBalance(key: string): InventoryBalance | undefined {
    return this.balances().find((balance) => balanceKey(balance) === key);
  }

  private locationId(code: string): string {
    return this.locations().find((location) => location.code === code)?.id || '';
  }

  private defaultMoveDestination(balance: InventoryBalance): string {
    return (
      this.locations().find(
        (location) =>
          location.id !== balance.storage_location_id &&
          location.code === 'INTERMEDIATE_INGREDIENT',
      )?.id ??
      this.locations().find((location) => location.id !== balance.storage_location_id)?.id ??
      ''
    );
  }

  private async runSave(operation: () => Promise<void>): Promise<void> {
    this.saving.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await operation();
    } catch (error) {
      this.errorMessage.set(this.errorText(error, 'Unable to save the inventory transaction.'));
    } finally {
      this.saving.set(false);
    }
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
