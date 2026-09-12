export type PackingVerificationStatus = 'verified' | 'sent_to_distribution';

export interface PackedRoundEntry {
  id: string;
  production_batch_id: string;
  sku_id: string;
  cases: number;
  loose_packets: number;
  recorded_at: string;
  production_batches: {
    batch_code: string;
    round_number: number;
    products: { name: string; variant: string | null } | null;
    production_shifts: {
      shift_number: number;
      shift_members: { person_name: string }[];
    } | null;
  } | null;
  skus: {
    code: string;
    description: string;
    unit_weight_g: number | null;
    packaging_configs: {
      packets_per_case: number | null;
      nominal_case_weight_kg: number | null;
      variable_case_allowed: boolean;
      effective_from: string;
      effective_to: string | null;
    }[];
  } | null;
}

export interface PackingVerification {
  id: string;
  sku_id: string;
  declared_cases: number;
  declared_loose_packets: number;
  corrected_cases: number;
  corrected_loose_packets: number;
  packets_per_case_used: number | null;
  case_weight_kg_used: number | null;
  verified_packet_quantity: number;
  source_round_uncertain: boolean;
  correction_reason: string | null;
  distributed_cases: number;
  distributed_loose_packets: number;
  distributed_packet_quantity: number;
  retained_loose_packets: number;
  distribution_exception_reason: string | null;
  status: PackingVerificationStatus;
  verified_at: string;
  sent_to_distribution_at: string | null;
}

export interface PackingVerificationSource {
  verification_id: string;
  packing_entry_id: string;
  production_batch_id: string;
  declared_cases: number;
  declared_loose_packets: number;
}

export interface RoundContribution {
  batchId: string;
  batchCode: string;
  shiftNumber: number | null;
  roundNumber: number | null;
  teamName: string;
  cases: number;
  loosePackets: number;
  entryCount: number;
  lastPackedAt: string;
}

export interface SkuPackingVerificationRow {
  key: string;
  skuId: string;
  productName: string;
  skuCode: string;
  skuDescription: string;
  declaredCases: number;
  declaredLoosePackets: number;
  entryCount: number;
  lastPackedAt: string;
  unitWeightG: number | null;
  packetsPerCase: number | null;
  caseWeightKg: number | null;
  variableCaseAllowed: boolean;
  contributions: RoundContribution[];
  verification: PackingVerification | null;
  needsReverification: boolean;
  correctedCases: number;
  correctedLoosePackets: number;
  sourceRoundUncertain: boolean;
  correctionReason: string;
  includeLooseInDistribution: boolean;
  distributionExceptionReason: string;
}

export interface PackingVerificationData {
  entries: PackedRoundEntry[];
  verifications: PackingVerification[];
  sources: PackingVerificationSource[];
  loosePools: LooseStockPool[];
  consolidations: LooseStockConsolidationHistory[];
}

export interface LooseStockPool {
  sku_id: string;
  sku_code: string;
  sku_description: string;
  packets_per_case: number | null;
  available_loose_packets: number;
  possible_cases: number;
  remainder_loose_packets: number;
  oldest_retained_at: string;
}

export interface LooseStockConsolidationHistory {
  id: string;
  consolidation_code: string;
  sku_id: string;
  sku_code: string;
  sku_description: string;
  packets_per_case_used: number;
  input_loose_packets: number;
  output_cases: number;
  consolidated_at: string;
  sent_to_distribution_at: string;
  consolidated_by_name: string | null;
  source_lot_codes: string;
}

export interface PackingVerificationView {
  activeRows: SkuPackingVerificationRow[];
  historyRows: SkuPackingVerificationRow[];
}

export interface VerifyPackingInput {
  skuId: string;
  correctedCases: number;
  correctedLoosePackets: number;
  packetsPerCase: number | null;
  caseWeightKg: number | null;
  sourceRoundUncertain: boolean;
  correctionReason: string;
}

export function buildPackingVerificationView(
  entries: PackedRoundEntry[],
  verifications: PackingVerification[],
  sources: PackingVerificationSource[],
): PackingVerificationView {
  const entryById = new Map(entries.map((entry) => [entry.id, entry]));
  const sentVerificationIds = new Set(
    verifications
      .filter((verification) => verification.status === 'sent_to_distribution')
      .map((verification) => verification.id),
  );
  const sentEntryIds = new Set(
    sources
      .filter((source) => sentVerificationIds.has(source.verification_id))
      .map((source) => source.packing_entry_id),
  );
  const activeVerificationBySku = new Map(
    verifications
      .filter((verification) => verification.status === 'verified')
      .map((verification) => [verification.sku_id, verification]),
  );
  const sourcesByVerification = groupSourcesByVerification(sources);

  const activeGroups = groupEntriesBySku(entries.filter((entry) => !sentEntryIds.has(entry.id)));
  const activeRows = [...activeGroups.entries()].map(([skuId, groupedEntries]) => {
    const verification = activeVerificationBySku.get(skuId) ?? null;
    const verificationSourceIds = new Set(
      (verification ? sourcesByVerification.get(verification.id) : [])?.map(
        (source) => source.packing_entry_id,
      ) ?? [],
    );
    const currentEntryIds = new Set(groupedEntries.map((entry) => entry.id));
    const needsReverification =
      verification !== null &&
      (!sameStringSet(verificationSourceIds, currentEntryIds) ||
        verification.declared_cases !== total(groupedEntries, 'cases') ||
        verification.declared_loose_packets !== total(groupedEntries, 'loose_packets'));
    return buildRow(`active:${skuId}`, groupedEntries, verification, needsReverification);
  });

  const historyRows = verifications
    .filter((verification) => verification.status === 'sent_to_distribution')
    .map((verification) => {
      const historyEntries = (sourcesByVerification.get(verification.id) ?? [])
        .map((source) => entryById.get(source.packing_entry_id))
        .filter((entry): entry is PackedRoundEntry => entry !== undefined);
      return buildRow(`history:${verification.id}`, historyEntries, verification, false);
    });

  return {
    activeRows: activeRows.sort((left, right) => left.skuCode.localeCompare(right.skuCode)),
    historyRows: historyRows.sort(
      (left, right) =>
        new Date(right.verification?.sent_to_distribution_at ?? 0).getTime() -
        new Date(left.verification?.sent_to_distribution_at ?? 0).getTime(),
    ),
  };
}

export function hasPackingVariance(row: SkuPackingVerificationRow): boolean {
  return (
    row.correctedCases !== row.declaredCases ||
    row.correctedLoosePackets !== row.declaredLoosePackets
  );
}

export function verifiedPacketTotal(row: SkuPackingVerificationRow): number | null {
  if (row.correctedCases > 0 && row.packetsPerCase === null) return null;
  return row.correctedCases * (row.packetsPerCase ?? 0) + row.correctedLoosePackets;
}

export function distributionPacketTotal(
  row: SkuPackingVerificationRow,
  includeLoosePackets = false,
): number | null {
  if (row.correctedCases > 0 && row.packetsPerCase === null) return null;
  return (
    row.correctedCases * (row.packetsPerCase ?? 0) +
    (includeLoosePackets ? row.correctedLoosePackets : 0)
  );
}

export function caseWeightFromPackets(
  packetsPerCase: number | null,
  unitWeightG: number | null,
): number | null {
  if (!packetsPerCase || !unitWeightG) return null;
  return (packetsPerCase * unitWeightG) / 1000;
}

export function packetsFromCaseWeight(
  caseWeightKg: number | null,
  unitWeightG: number | null,
): number | null {
  if (!caseWeightKg || !unitWeightG) return null;
  return Math.max(1, Math.round((caseWeightKg * 1000) / unitWeightG));
}

function buildRow(
  key: string,
  entries: PackedRoundEntry[],
  verification: PackingVerification | null,
  needsReverification: boolean,
): SkuPackingVerificationRow {
  const first = entries[0];
  const isHistory = verification?.status === 'sent_to_distribution';
  const declaredCases = isHistory ? verification.declared_cases : total(entries, 'cases');
  const declaredLoosePackets = isHistory
    ? verification.declared_loose_packets
    : total(entries, 'loose_packets');
  const activeConfig = currentPackagingConfig(first?.skus?.packaging_configs ?? []);
  const packetsPerCase =
    verification?.packets_per_case_used ?? activeConfig?.packets_per_case ?? null;
  const unitWeightG = first?.skus?.unit_weight_g ?? null;
  return {
    key,
    skuId: verification?.sku_id ?? first?.sku_id ?? '',
    productName: first?.production_batches?.products?.name ?? 'Unknown product',
    skuCode: first?.skus?.code ?? 'Unknown SKU',
    skuDescription: first?.skus?.description ?? '',
    declaredCases,
    declaredLoosePackets,
    entryCount: entries.length,
    lastPackedAt: latestPackedAt(entries, verification),
    unitWeightG,
    packetsPerCase,
    caseWeightKg:
      verification?.case_weight_kg_used ??
      activeConfig?.nominal_case_weight_kg ??
      caseWeightFromPackets(packetsPerCase, unitWeightG),
    variableCaseAllowed: activeConfig?.variable_case_allowed ?? false,
    contributions: groupRoundContributions(entries),
    verification,
    needsReverification,
    correctedCases: verification?.corrected_cases ?? declaredCases,
    correctedLoosePackets: verification?.corrected_loose_packets ?? declaredLoosePackets,
    sourceRoundUncertain: verification?.source_round_uncertain ?? false,
    correctionReason: verification?.correction_reason ?? '',
    includeLooseInDistribution: false,
    distributionExceptionReason: '',
  };
}

function groupEntriesBySku(entries: PackedRoundEntry[]): Map<string, PackedRoundEntry[]> {
  const groups = new Map<string, PackedRoundEntry[]>();
  for (const entry of entries) {
    groups.set(entry.sku_id, [...(groups.get(entry.sku_id) ?? []), entry]);
  }
  return groups;
}

function groupSourcesByVerification(
  sources: PackingVerificationSource[],
): Map<string, PackingVerificationSource[]> {
  const groups = new Map<string, PackingVerificationSource[]>();
  for (const source of sources) {
    groups.set(source.verification_id, [...(groups.get(source.verification_id) ?? []), source]);
  }
  return groups;
}

function groupRoundContributions(entries: PackedRoundEntry[]): RoundContribution[] {
  const groups = new Map<string, RoundContribution>();
  for (const entry of entries) {
    const batch = entry.production_batches;
    const existing = groups.get(entry.production_batch_id);
    if (existing) {
      existing.cases += Number(entry.cases);
      existing.loosePackets += Number(entry.loose_packets);
      existing.entryCount += 1;
      if (entry.recorded_at > existing.lastPackedAt) existing.lastPackedAt = entry.recorded_at;
      continue;
    }
    groups.set(entry.production_batch_id, {
      batchId: entry.production_batch_id,
      batchCode: batch?.batch_code ?? 'Unknown batch',
      shiftNumber: batch?.production_shifts?.shift_number ?? null,
      roundNumber: batch?.round_number ?? null,
      teamName:
        batch?.production_shifts?.shift_members.map((member) => member.person_name).join(', ') ||
        'Not recorded',
      cases: Number(entry.cases),
      loosePackets: Number(entry.loose_packets),
      entryCount: 1,
      lastPackedAt: entry.recorded_at,
    });
  }
  return [...groups.values()].sort(
    (left, right) =>
      (left.shiftNumber ?? 0) - (right.shiftNumber ?? 0) ||
      (left.roundNumber ?? 0) - (right.roundNumber ?? 0),
  );
}

function total(entries: PackedRoundEntry[], field: 'cases' | 'loose_packets'): number {
  return entries.reduce((sum, entry) => sum + Number(entry[field]), 0);
}

function latestPackedAt(
  entries: PackedRoundEntry[],
  verification: PackingVerification | null,
): string {
  return entries.reduce(
    (latest, entry) => (entry.recorded_at > latest ? entry.recorded_at : latest),
    verification?.verified_at ?? '',
  );
}

function sameStringSet(left: Set<string>, right: Set<string>): boolean {
  return left.size === right.size && [...left].every((value) => right.has(value));
}

function currentPackagingConfig(
  configs: NonNullable<PackedRoundEntry['skus']>['packaging_configs'],
): {
  packets_per_case: number | null;
  nominal_case_weight_kg: number | null;
  variable_case_allowed: boolean;
} | null {
  const today = new Date().toISOString().slice(0, 10);
  return (
    configs
      .filter(
        (config) =>
          config.effective_from <= today &&
          (config.effective_to === null || config.effective_to >= today),
      )
      .sort((left, right) => right.effective_from.localeCompare(left.effective_from))[0] ?? null
  );
}
