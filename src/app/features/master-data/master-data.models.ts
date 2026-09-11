export interface PackagingConfig {
  units_per_inner_pack: number | null;
  packets_per_case: number | null;
  nominal_case_weight_kg: number | null;
  variable_case_allowed: boolean;
}

export interface SkuSummary {
  id: string;
  code: string;
  description: string;
  unit_weight_g: number | null;
  pieces_per_packet: number | null;
  packaging_configs: PackagingConfig[];
}

export interface ProductSummary {
  id: string;
  code: string;
  name: string;
  product_type: 'raw' | 'intermediate' | 'finished';
  variant: string | null;
  active: boolean;
  product_families: { name: string } | null;
  skus: SkuSummary[];
}

export interface LocationSummary {
  id: string;
  code: string;
  name: string;
  location_type: string;
  active: boolean;
  temperature_profiles: { name: string } | null;
}

export function packagingDescription(config: PackagingConfig | undefined): string {
  if (!config) return 'Configuration pending';
  if (config.variable_case_allowed) return 'Variable case configuration';

  const parts: string[] = [];
  if (config.units_per_inner_pack) parts.push(`${config.units_per_inner_pack} units/packet`);
  if (config.packets_per_case) parts.push(`${config.packets_per_case} packets/case`);
  if (config.nominal_case_weight_kg) parts.push(`${config.nominal_case_weight_kg} kg/case`);
  return parts.join(' · ') || 'Configuration pending';
}
