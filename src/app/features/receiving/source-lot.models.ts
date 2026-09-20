export type SourceLotType = 'milk' | 'purchased_cream';
export type SourceLotStatus = 'accepted' | 'rejected' | 'closed';

export interface SourceLotAllocation {
  quantity: number;
}

export interface SourceLotMilkSale {
  id: string;
  source_lot_id: string;
  sale_date: string;
  customer: string;
  quantity: number;
}

export interface SourceLotProductionBatch {
  id: string;
  parent_source_lot_id: string;
  actual_primary_input_quantity: number | null;
  gross_output_quantity: number | null;
  cut_format: string | null;
  status: string;
  products: { variant: string | null } | null;
  production_round_blocks: Array<{ weight_kg: number | null }>;
  production_round_cream_buckets: Array<{ weight_kg: number }>;
  production_round_packing_entries: Array<{
    cases: number;
    loose_packets: number;
    skus: {
      code: string;
      unit_weight_g?: number | null;
      packaging_configs?: {
        packets_per_case: number | null;
        nominal_case_weight_kg: number | null;
      }[];
    } | null;
  }>;
  transformations: Array<{
    source_quantity: number;
    cut_type: string | null;
    transformation_outputs: Array<{
      quantity: number;
      output_label: string;
      products: { code: string } | null;
    }>;
  }>;
}

export interface SkuProductionTotal {
  skuCode: string;
  cases: number;
  loosePackets: number;
  weightKg: number;
}

export interface MilkLotProductionSummary {
  milkConsumedLitres: number;
  paneerProducedKg: number;
  litresPerKg: number | null;
  yieldKgPer100L: number | null;
  dRounds: number;
  csRounds: number;
  creamKg: number;
  skuTotals: SkuProductionTotal[];
  pan111Kg: number;
  sppPaneerKg: number;
}

export interface SourceLotSummary {
  id: string;
  lot_type: SourceLotType;
  lot_code: string;
  invoice_number: string | null;
  received_from: string | null;
  received_at: string;
  received_quantity: number;
  status: SourceLotStatus;
  notes: string | null;
  locked_at: string | null;
  unaccounted_loss_quantity: number | null;
  closure_notes: string | null;
  units_of_measure: { code: string } | null;
  suppliers: { name: string } | null;
  source_lot_allocations: SourceLotAllocation[];
  source_lot_milk_sales: SourceLotMilkSale[];
  production_batches: SourceLotProductionBatch[];
}

export interface CreateSourceLotInput {
  lotType: SourceLotType;
  lotCode: string;
  invoiceNumber: string;
  receivedFrom: string;
  receivedAt: string;
  receivedQuantity: number;
  status: Exclude<SourceLotStatus, 'closed'>;
  notes: string | null;
}

export interface UpdateSourceLotInput extends CreateSourceLotInput {
  id: string;
}

export function allocatedQuantity(allocations: SourceLotAllocation[]): number {
  return allocations.reduce((total, allocation) => total + Number(allocation.quantity), 0);
}

export function productionQuantity(batches: SourceLotProductionBatch[]): number {
  return batches
    .filter((batch) => batch.status !== 'cancelled')
    .reduce((total, batch) => total + Number(batch.actual_primary_input_quantity || 0), 0);
}

export function milkSoldQuantity(sales: SourceLotMilkSale[]): number {
  return sales.reduce((total, sale) => total + Number(sale.quantity), 0);
}

export function remainingQuantity(lot: SourceLotSummary): number {
  if (lot.status === 'closed') return 0;
  const committed = Math.max(
    allocatedQuantity(lot.source_lot_allocations),
    productionQuantity(lot.production_batches),
  );
  return Math.max(
    0,
    Number(lot.received_quantity) - committed - milkSoldQuantity(lot.source_lot_milk_sales),
  );
}

export function summarizeMilkLotProduction(lot: SourceLotSummary): MilkLotProductionSummary {
  const batches = lot.production_batches.filter((batch) => batch.status !== 'cancelled');
  const milkConsumedLitres = batches.reduce(
    (total, batch) => total + Number(batch.actual_primary_input_quantity || 0),
    0,
  );
  const paneerProducedKg = batches.reduce(
    (total, batch) =>
      total +
      batch.production_round_blocks.reduce(
        (batchTotal, block) => batchTotal + Number(block.weight_kg || 0),
        0,
      ),
    0,
  );
  const creamKg = batches.reduce(
    (total, batch) =>
      total +
      batch.production_round_cream_buckets.reduce(
        (batchTotal, bucket) => batchTotal + Number(bucket.weight_kg || 0),
        0,
      ),
    0,
  );
  const skuMap = new Map<string, SkuProductionTotal>();
  let pan111Kg = 0;
  let sppPaneerKg = 0;

  for (const batch of batches) {
    for (const packing of batch.production_round_packing_entries) {
      const skuCode = packing.skus?.code ?? 'Unknown SKU';
      const total = skuMap.get(skuCode) ?? { skuCode, cases: 0, loosePackets: 0, weightKg: 0 };
      total.cases += Number(packing.cases);
      total.loosePackets += Number(packing.loose_packets);
      const packetWeight = Number(packing.skus?.unit_weight_g || 0) / 1000;
      const configuredPackets = Number(packing.skus?.packaging_configs?.[0]?.packets_per_case || 0);
      const configuredCaseWeight = Number(
        packing.skus?.packaging_configs?.[0]?.nominal_case_weight_kg || 0,
      );
      const knownCaseWeight = ['MPAN010', 'RPAN010'].includes(skuCode) ? 20 : 0;
      total.weightKg +=
        Number(packing.cases) *
          (configuredCaseWeight || knownCaseWeight || configuredPackets * packetWeight) +
        Number(packing.loose_packets) * packetWeight;
      skuMap.set(skuCode, total);
    }

    for (const transformation of batch.transformations) {
      pan111Kg += transformation.transformation_outputs
        .filter((output) => output.products?.code === 'PAN111')
        .reduce((total, output) => total + Number(output.quantity), 0);
    }

    const sppTransformations = batch.transformations.filter((transformation) =>
      transformation.cut_type?.toLowerCase().includes('spp'),
    );
    if (sppTransformations.length > 0) {
      sppPaneerKg += sppTransformations.reduce(
        (total, transformation) => total + Number(transformation.source_quantity),
        0,
      );
    } else if (batch.cut_format === 'spp') {
      sppPaneerKg += batch.production_round_blocks.reduce(
        (total, block) => total + Number(block.weight_kg || 0),
        0,
      );
    }
  }

  return {
    milkConsumedLitres,
    paneerProducedKg,
    litresPerKg: paneerProducedKg > 0 ? milkConsumedLitres / paneerProducedKg : null,
    yieldKgPer100L: milkConsumedLitres > 0 ? (paneerProducedKg / milkConsumedLitres) * 100 : null,
    dRounds: batches.filter((batch) => batch.products?.variant === 'D').length,
    csRounds: batches.filter((batch) => batch.products?.variant === 'C/S').length,
    creamKg,
    skuTotals: [...skuMap.values()].sort((left, right) =>
      left.skuCode.localeCompare(right.skuCode),
    ),
    pan111Kg,
    sppPaneerKg,
  };
}
