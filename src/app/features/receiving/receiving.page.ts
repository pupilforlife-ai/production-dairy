import { DatePipe, DecimalPipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import type {
  MilkLotProductionSummary,
  SourceLotSummary,
  SourceLotType,
} from './source-lot.models';
import {
  milkSoldQuantity,
  remainingQuantity,
  summarizeMilkLotProduction,
} from './source-lot.models';
import { SourceLotService } from './source-lot.service';

@Component({
  selector: 'app-receiving-page',
  imports: [DatePipe, DecimalPipe, ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './receiving.page.html',
})
export class ReceivingPage implements OnInit {
  private readonly sourceLots = inject(SourceLotService);
  readonly auth = inject(AuthService);
  readonly closeFeatureAvailable = this.sourceLots.closeFeatureAvailable;
  readonly milkSalesFeatureAvailable = this.sourceLots.milkSalesFeatureAvailable;
  readonly lots = signal<SourceLotSummary[]>([]);
  readonly loading = signal(true);
  readonly submitting = signal(false);
  readonly closing = signal(false);
  readonly recordingSale = signal(false);
  readonly showForm = signal(false);
  readonly editingId = signal<string | null>(null);
  readonly closingId = signal<string | null>(null);
  readonly saleLotId = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly expandedProductionLotIds = signal<Set<string>>(new Set());
  readonly remaining = remainingQuantity;
  readonly milkSold = milkSoldQuantity;
  readonly milkTableTotals = computed(() => {
    const milkLots = this.lots().filter(
      (lot) => lot.lot_type === 'milk' && lot.status !== 'rejected',
    );
    const summaries = milkLots.map((lot) => summarizeMilkLotProduction(lot));
    const milkConsumedLitres = summaries.reduce(
      (total, summary) => total + summary.milkConsumedLitres,
      0,
    );

    return {
      receivedLitres: milkLots.reduce((total, lot) => total + Number(lot.received_quantity), 0),
      milkConsumedLitres,
      milkSoldLitres: milkLots.reduce(
        (total, lot) => total + milkSoldQuantity(lot.source_lot_milk_sales),
        0,
      ),
      remainingLitres: milkLots.reduce((total, lot) => total + remainingQuantity(lot), 0),
    };
  });

  readonly form = new FormGroup({
    lotType: new FormControl<SourceLotType>('milk', { nonNullable: true }),
    lotCode: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    invoiceNumber: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    receivedFrom: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    receivedAt: new FormControl(this.localDateTime(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    receivedQuantity: new FormControl<number | null>(null, [
      Validators.required,
      Validators.min(0.001),
    ]),
    status: new FormControl<'accepted' | 'rejected'>('accepted', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
  });

  readonly editForm = new FormGroup({
    lotType: new FormControl<SourceLotType>('milk', { nonNullable: true }),
    lotCode: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    invoiceNumber: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    receivedFrom: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    receivedAt: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    receivedQuantity: new FormControl<number | null>(null, [
      Validators.required,
      Validators.min(0.001),
    ]),
    status: new FormControl<'accepted' | 'rejected'>('accepted', { nonNullable: true }),
    notes: new FormControl('', { nonNullable: true }),
  });

  readonly closeForm = new FormGroup({
    closureNotes: new FormControl('', { nonNullable: true }),
  });

  readonly saleForm = new FormGroup({
    saleDate: new FormControl(this.localDate(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    customer: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
  });

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  async submit(): Promise<void> {
    if (!this.auth.hasRole('owner')) return;
    if (this.form.invalid || this.submitting()) {
      this.form.markAllAsTouched();
      return;
    }
    const values = this.form.getRawValue();
    if (values.receivedQuantity === null) return;

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.sourceLots.create({
        lotType: values.lotType,
        lotCode: values.lotCode,
        invoiceNumber: values.invoiceNumber,
        receivedFrom: values.receivedFrom,
        receivedAt: values.receivedAt,
        receivedQuantity: values.receivedQuantity,
        status: values.status,
        notes: values.notes,
      });
      this.successMessage.set(`Source lot ${values.lotCode.trim()} recorded.`);
      this.form.reset({
        lotType: 'milk',
        lotCode: '',
        invoiceNumber: '',
        receivedFrom: '',
        receivedAt: this.localDateTime(),
        receivedQuantity: null,
        status: 'accepted',
        notes: '',
      });
      this.showForm.set(false);
      await this.load();
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to record source lot.',
      );
    } finally {
      this.submitting.set(false);
    }
  }

  beginEdit(lot: SourceLotSummary): void {
    if (!this.auth.hasRole('owner') || lot.locked_at || lot.status === 'closed') return;
    this.editingId.set(lot.id);
    this.closingId.set(null);
    this.saleLotId.set(null);
    this.showForm.set(false);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    this.editForm.reset({
      lotType: lot.lot_type,
      lotCode: lot.lot_code,
      invoiceNumber: lot.invoice_number ?? '',
      receivedFrom: lot.received_from ?? lot.suppliers?.name ?? '',
      receivedAt: this.localDateTime(lot.received_at),
      receivedQuantity: Number(lot.received_quantity),
      status: lot.status === 'rejected' ? 'rejected' : 'accepted',
      notes: lot.notes ?? '',
    });
  }

  cancelEdit(): void {
    this.editingId.set(null);
  }

  beginClose(lot: SourceLotSummary): void {
    if (
      !this.auth.hasRole('owner') ||
      lot.lot_type !== 'milk' ||
      lot.status !== 'accepted' ||
      lot.locked_at
    ) {
      return;
    }
    this.closingId.set(lot.id);
    this.editingId.set(null);
    this.saleLotId.set(null);
    this.closeForm.reset({ closureNotes: '' });
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  cancelClose(): void {
    this.closingId.set(null);
  }

  async closeProduction(lot: SourceLotSummary): Promise<void> {
    if (!this.auth.hasRole('owner') || this.closing() || this.closingId() !== lot.id) return;

    this.closing.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      const lossQuantity = await this.sourceLots.closeMilkProduction(
        lot.id,
        this.closeForm.controls.closureNotes.value.trim() || null,
      );
      this.successMessage.set(
        `Milk production ${lot.lot_code} closed and locked. ${lossQuantity.toFixed(1)} L recorded as unaccounted process loss/spillage.`,
      );
      this.closingId.set(null);
      await this.load();
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to close milk production.',
      );
    } finally {
      this.closing.set(false);
    }
  }

  beginMilkSale(lot: SourceLotSummary): void {
    if (
      !this.auth.hasRole('owner') ||
      !this.milkSalesFeatureAvailable() ||
      lot.lot_type !== 'milk' ||
      lot.status !== 'accepted' ||
      lot.locked_at
    ) {
      return;
    }
    this.saleLotId.set(lot.id);
    this.editingId.set(null);
    this.closingId.set(null);
    this.saleForm.reset({ saleDate: this.localDate(), customer: '', quantity: null });
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  cancelMilkSale(): void {
    this.saleLotId.set(null);
  }

  async recordMilkSale(lot: SourceLotSummary): Promise<void> {
    if (
      !this.auth.hasRole('owner') ||
      this.saleForm.invalid ||
      this.recordingSale() ||
      this.saleLotId() !== lot.id
    ) {
      this.saleForm.markAllAsTouched();
      return;
    }
    const values = this.saleForm.getRawValue();
    if (values.quantity === null) return;

    this.recordingSale.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.sourceLots.recordMilkSale({
        sourceLotId: lot.id,
        saleDate: values.saleDate,
        customer: values.customer.trim(),
        quantity: values.quantity,
      });
      this.successMessage.set(
        `${values.quantity.toFixed(1)} L milk sale to ${values.customer.trim()} recorded.`,
      );
      this.saleLotId.set(null);
      await this.load();
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to record the milk sale.',
      );
    } finally {
      this.recordingSale.set(false);
    }
  }

  productionSummary(lot: SourceLotSummary): MilkLotProductionSummary {
    return summarizeMilkLotProduction(lot);
  }

  isLatestMilk(lotId: string): boolean {
    return this.lots().find((lot) => lot.lot_type === 'milk')?.id === lotId;
  }

  isProductionExpanded(lotId: string): boolean {
    return this.expandedProductionLotIds().has(lotId);
  }

  toggleProduction(lotId: string): void {
    this.expandedProductionLotIds.update((expandedIds) => {
      const next = new Set(expandedIds);
      if (next.has(lotId)) next.delete(lotId);
      else next.add(lotId);
      return next;
    });
  }

  async submitEdit(lot: SourceLotSummary): Promise<void> {
    if (
      !this.auth.hasRole('owner') ||
      this.editForm.invalid ||
      this.submitting() ||
      this.editingId() !== lot.id
    ) {
      this.editForm.markAllAsTouched();
      return;
    }
    const values = this.editForm.getRawValue();
    if (values.receivedQuantity === null) return;

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.sourceLots.update({
        id: lot.id,
        lotType: values.lotType,
        lotCode: values.lotCode,
        invoiceNumber: values.invoiceNumber,
        receivedFrom: values.receivedFrom,
        receivedAt: values.receivedAt,
        receivedQuantity: values.receivedQuantity,
        status: values.status,
        notes: values.notes.trim() || null,
      });
      this.successMessage.set(`Source lot ${values.lotCode.trim()} updated.`);
      this.editingId.set(null);
      await this.load();
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to update source lot.',
      );
    } finally {
      this.submitting.set(false);
    }
  }

  private async load(): Promise<void> {
    this.loading.set(true);
    try {
      const lots = await this.sourceLots.listRecent();
      this.lots.set(lots);
      if (this.expandedProductionLotIds().size === 0) {
        const latestMilk = lots.find((lot) => lot.lot_type === 'milk');
        if (latestMilk) this.expandedProductionLotIds.set(new Set([latestMilk.id]));
      }
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to load source lots.');
    } finally {
      this.loading.set(false);
    }
  }

  private localDateTime(value?: string): string {
    const date = value ? new Date(value) : new Date();
    const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
    return local.toISOString().slice(0, 16);
  }

  private localDate(): string {
    return this.localDateTime().slice(0, 10);
  }
}
