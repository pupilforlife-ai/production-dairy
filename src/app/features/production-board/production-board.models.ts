export type ProductionStatus =
  | 'scheduled'
  | 'in_production'
  | 'pressing'
  | 'ready_for_cutting'
  | 'cut'
  | 'freezing'
  | 'frozen_ready_for_packing'
  | 'part_packed'
  | 'packed'
  | 'ready_for_handover'
  | 'handed_over'
  | 'cancelled';

export type PaneerProcessStage =
  | 'vat_1'
  | 'vat_2'
  | 'vat_3'
  | 'coagulation'
  | 'presses'
  | 'cooling_tank'
  | 'chiller'
  | 'resting'
  | 'ready_for_cutting';

export type PaneerCutFormat =
  'cubes_200g' | 'cubes_400g' | 'spp' | 'restaurant_blocks' | 'cling_wrapped';

export type IngredientAdditionStage = 'processing_vat' | 'coagulation';

export interface SourceLotOption {
  id: string;
  lot_code: string;
  received_at: string;
  received_quantity: number;
  uom_id: string;
  units_of_measure: { code: string } | null;
}

export interface ProductOption {
  id: string;
  code: string;
  name: string;
  variant: string | null;
}

export interface BoardSku {
  id: string;
  product_id: string;
  code: string;
  description: string;
  packaging_configs: { packets_per_case: number | null }[];
}

export interface ProductionStageEvent {
  id: string;
  stage: PaneerProcessStage;
  changed_at: string;
}

export interface RoundPackingEntry {
  id: string;
  production_batch_id: string;
  sku_id: string;
  cases: number;
  loose_packets: number;
  recorded_at: string;
  skus: { code: string; description: string } | null;
}

export interface PressedPaneerBlock {
  id: string;
  production_batch_id: string;
  block_number: number;
  weight_kg: number | null;
  updated_at: string;
}

export interface ProductionHandlingEvent {
  id: string;
  production_batch_id: string;
  event_type: 'cling_wrapped';
  recorded_at: string;
  profiles: { display_name: string | null } | null;
}

export interface ProductionCreamBucket {
  id: string;
  production_batch_id: string;
  bucket_number: number;
  weight_kg: number;
  recorded_at: string;
  intermediate_lots: {
    lot_code: string;
    storage_locations: { name: string } | null;
  } | null;
  profiles: { display_name: string | null } | null;
}

export interface ProductionIngredientIssue {
  id: string;
  production_batch_id: string;
  addition_stage: IngredientAdditionStage;
  required_quantity: number;
  issued_quantity: number;
  shortage_quantity: number;
  last_attempted_at: string;
  units_of_measure: { code: string } | null;
  recipe_components: { ingredients: { name: string } | null } | null;
}

export interface IngredientIssueSummary {
  componentCount: number;
  shortageCount: number;
  hasShortage: boolean;
}

export interface BlockWeightSummary {
  expectedCount: number;
  recordedCount: number;
  totalWeightKg: number;
  averageWeightKg: number | null;
  anomalyCount: number;
  complete: boolean;
}

export interface ShiftSummary {
  id: string;
  source_lot_id: string;
  shift_number: number;
  started_at: string;
  ended_at: string | null;
  status: 'open' | 'completed' | 'cancelled';
  team_notes: string | null;
  source_lots: { lot_code: string; received_at: string } | null;
  shift_members: { person_name: string }[];
}

export interface ProductionBatchSummary {
  id: string;
  batch_code: string;
  parent_source_lot_id: string;
  shift_id: string;
  round_number: number;
  product_id: string;
  recipe_version_id: string | null;
  planned_input_quantity: number | null;
  actual_primary_input_quantity: number | null;
  gross_output_quantity: number | null;
  pressed_block_count: number | null;
  milk_start_temperature_c: number | null;
  process_stage: PaneerProcessStage;
  process_stage_changed_at: string;
  cut_by: string | null;
  cut_format: PaneerCutFormat | null;
  cut_completed_at: string | null;
  cutting_allocation: string | null;
  status: ProductionStatus;
  started_at: string | null;
  completed_at: string | null;
  notes: string | null;
  locked_at: string | null;
  source_lots: { lot_code: string } | null;
  products: ProductOption | null;
  production_shifts: {
    shift_number: number;
    shift_members: { person_name: string }[];
  } | null;
  input_uom: { code: string } | null;
  output_uom: { code: string } | null;
  production_batch_stage_events: ProductionStageEvent[];
}

export interface BoardData {
  sourceLots: SourceLotOption[];
  products: ProductOption[];
  shifts: ShiftSummary[];
  batches: ProductionBatchSummary[];
  skus: BoardSku[];
  packingEntries: RoundPackingEntry[];
  blocks: PressedPaneerBlock[];
  handlingEvents: ProductionHandlingEvent[];
  creamBuckets: ProductionCreamBucket[];
  ingredientIssues: ProductionIngredientIssue[];
}

export function summarizeIngredientIssues(
  issues: ProductionIngredientIssue[],
): IngredientIssueSummary {
  const shortageCount = issues.filter((issue) => Number(issue.shortage_quantity) > 0).length;
  return {
    componentCount: issues.length,
    shortageCount,
    hasShortage: shortageCount > 0,
  };
}

export const PANEER_STAGE_OPTIONS: ReadonlyArray<{
  value: PaneerProcessStage;
  label: string;
}> = [
  { value: 'vat_1', label: 'VAT 1' },
  { value: 'vat_2', label: 'VAT 2' },
  { value: 'vat_3', label: 'VAT 3' },
  { value: 'coagulation', label: 'Coagulation' },
  { value: 'presses', label: 'Presses' },
  { value: 'cooling_tank', label: 'Cooling Tank' },
  { value: 'chiller', label: 'Chiller' },
  { value: 'resting', label: 'Resting' },
  { value: 'ready_for_cutting', label: 'Ready for Cutting' },
];

export const CUT_FORMAT_OPTIONS: ReadonlyArray<{
  value: PaneerCutFormat;
  label: string;
}> = [
  { value: 'cubes_200g', label: '200 g cubes' },
  { value: 'cubes_400g', label: '400 g cubes' },
  { value: 'spp', label: 'SPP' },
  { value: 'restaurant_blocks', label: 'Restaurant blocks' },
  { value: 'cling_wrapped', label: 'Cling wrapped — stored in chiller' },
];

export interface StageTimer {
  ready: boolean;
  prompt: 'Ready for cooling' | 'Ready to take out' | 'Ready for cutting';
  remainingMinutes: number;
  deadline: Date;
}

export function paneerStageLabel(stage: PaneerProcessStage): string {
  return PANEER_STAGE_OPTIONS.find((option) => option.value === stage)?.label ?? stage;
}

export function receivedDateBatchCode(receivedAt: string): string {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Africa/Johannesburg',
    day: '2-digit',
    month: '2-digit',
    year: '2-digit',
  }).formatToParts(new Date(receivedAt));
  const value = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? '';
  return `${value('day')}${value('month')}${value('year')}`;
}

export function getStageTimer(
  stage: PaneerProcessStage,
  changedAt: string,
  now = new Date(),
): StageTimer | null {
  const durationMinutes =
    stage === 'presses'
      ? 30
      : stage === 'chiller'
        ? 120
        : stage === 'cooling_tank' || stage === 'resting'
          ? 90
          : null;
  if (durationMinutes === null) return null;

  const deadline = new Date(new Date(changedAt).getTime() + durationMinutes * 60_000);
  const remainingMinutes = Math.max(0, Math.ceil((deadline.getTime() - now.getTime()) / 60_000));
  return {
    ready: remainingMinutes === 0,
    prompt:
      stage === 'presses'
        ? 'Ready for cooling'
        : stage === 'resting'
          ? 'Ready for cutting'
          : 'Ready to take out',
    remainingMinutes,
    deadline,
  };
}

export function formatRemainingTime(totalMinutes: number): string {
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (hours === 0) return `${minutes}m remaining`;
  if (minutes === 0) return `${hours}h remaining`;
  return `${hours}h ${minutes}m remaining`;
}

export function summarizeBlockWeights(
  expectedCount: number | null,
  blocks: PressedPaneerBlock[],
): BlockWeightSummary {
  const weights = blocks
    .map((block) => block.weight_kg)
    .filter((weight): weight is number => weight !== null);
  const totalWeightKg = weights.reduce((total, weight) => total + Number(weight), 0);
  return {
    expectedCount: expectedCount ?? 0,
    recordedCount: weights.length,
    totalWeightKg,
    averageWeightKg: weights.length ? totalWeightKg / weights.length : null,
    anomalyCount: weights.filter((weight) => weight > 13).length,
    complete: expectedCount !== null && expectedCount > 0 && weights.length === expectedCount,
  };
}

export function summarizeCreamBuckets(buckets: ProductionCreamBucket[]): {
  count: number;
  totalWeightKg: number;
} {
  return {
    count: buckets.length,
    totalWeightKg: buckets.reduce((total, bucket) => total + Number(bucket.weight_kg), 0),
  };
}

export const PRODUCTION_STATUS_OPTIONS: ReadonlyArray<{
  value: ProductionStatus;
  label: string;
}> = [
  { value: 'scheduled', label: 'Scheduled' },
  { value: 'in_production', label: 'In production' },
  { value: 'pressing', label: 'Pressing' },
  { value: 'ready_for_cutting', label: 'Ready for cutting' },
  { value: 'cut', label: 'Cut' },
  { value: 'freezing', label: 'Freezing' },
  { value: 'frozen_ready_for_packing', label: 'Frozen / ready for packing' },
  { value: 'part_packed', label: 'Part packed' },
  { value: 'packed', label: 'Packed' },
  { value: 'ready_for_handover', label: 'Ready for handover' },
  { value: 'handed_over', label: 'Handed over' },
  { value: 'cancelled', label: 'Cancelled' },
];

export function productionStatusLabel(status: ProductionStatus): string {
  return PRODUCTION_STATUS_OPTIONS.find((option) => option.value === status)?.label ?? status;
}

export function buildBatchCode(
  lotCode: string,
  shiftNumber: number,
  roundNumber: number,
  variant: string | null,
): string {
  const safeLot = lotCode
    .trim()
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, '-')
    .replace(/^-|-$/g, '');
  const safeVariant = (variant || 'NA').toUpperCase().replace(/[^A-Z0-9]+/g, '');
  return `${safeLot}-S${String(shiftNumber).padStart(2, '0')}-R${String(roundNumber).padStart(2, '0')}-${safeVariant}`;
}

export function isDateInCurrentWeek(isoDate: string | null, now = new Date()): boolean {
  if (!isoDate) return false;
  const date = new Date(isoDate);
  const start = new Date(now);
  const day = (start.getDay() + 6) % 7;
  start.setHours(0, 0, 0, 0);
  start.setDate(start.getDate() - day);
  const end = new Date(start);
  end.setDate(end.getDate() + 7);
  return date >= start && date < end;
}
