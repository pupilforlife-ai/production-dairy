import { Component, OnInit, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import type { LocationSummary, ProductSummary } from './master-data.models';
import { packagingDescription } from './master-data.models';
import { MasterDataService } from './master-data.service';

@Component({
  selector: 'app-master-data-page',
  imports: [RouterLink, NavigationRailComponent],
  templateUrl: './master-data.page.html',
})
export class MasterDataPage implements OnInit {
  private readonly masterData = inject(MasterDataService);
  readonly products = signal<ProductSummary[]>([]);
  readonly locations = signal<LocationSummary[]>([]);
  readonly loading = signal(true);
  readonly savingId = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly describePackaging = packagingDescription;

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  async toggleProduct(product: ProductSummary): Promise<void> {
    this.savingId.set(product.id);
    this.errorMessage.set(null);
    try {
      await this.masterData.setProductActive(product.id, !product.active);
      this.products.update((products) =>
        products.map((item) =>
          item.id === product.id ? { ...item, active: !product.active } : item,
        ),
      );
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to update product.');
    } finally {
      this.savingId.set(null);
    }
  }

  private async load(): Promise<void> {
    this.loading.set(true);
    this.errorMessage.set(null);
    try {
      const [products, locations] = await Promise.all([
        this.masterData.listProducts(),
        this.masterData.listLocations(),
      ]);
      this.products.set(products);
      this.locations.set(locations);
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to load master data.');
    } finally {
      this.loading.set(false);
    }
  }
}
