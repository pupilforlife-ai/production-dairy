import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type { LocationSummary, ProductSummary } from './master-data.models';

@Injectable({ providedIn: 'root' })
export class MasterDataService {
  private readonly supabase = inject(SupabaseService).client;

  async listProducts(): Promise<ProductSummary[]> {
    const { data, error } = await this.supabase
      .from('products')
      .select(
        'id, code, name, product_type, variant, active, product_families(name), skus(id, code, description, unit_weight_g, pieces_per_packet, packaging_configs(units_per_inner_pack, packets_per_case, nominal_case_weight_kg, variable_case_allowed))',
      )
      .order('name');
    if (error) throw error;
    return data as unknown as ProductSummary[];
  }

  async listLocations(): Promise<LocationSummary[]> {
    const { data, error } = await this.supabase
      .from('storage_locations')
      .select('id, code, name, location_type, active, temperature_profiles(name)')
      .order('name');
    if (error) throw error;
    return data as unknown as LocationSummary[];
  }

  async setProductActive(id: string, active: boolean): Promise<void> {
    const { error } = await this.supabase.from('products').update({ active }).eq('id', id);
    if (error) throw error;
  }
}
