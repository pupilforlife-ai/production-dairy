export interface ActivityFieldChange {
  field: string;
  from: unknown;
  to: unknown;
}

export interface ActivityEvent {
  id: string;
  entity_type: string;
  entity_id: string | null;
  action: 'insert' | 'update' | 'delete' | string;
  occurred_at: string;
  actor_user_id: string | null;
  actor_display_name: string;
  actor_role: string | null;
  entity_label: string | null;
  changed_fields: ActivityFieldChange[];
  reason: string | null;
}

export const ACTIVITY_ENTITY_LABELS: Record<string, string> = {
  profiles: 'User',
  source_lots: 'Milk receipt',
  source_lot_allocations: 'Milk allocation',
  production_shifts: 'Production shift',
  shift_members: 'Shift member',
  production_batches: 'Production round',
  production_batch_stage_events: 'Stage change',
  production_round_blocks: 'Pressed block',
  production_round_cream_buckets: 'Cream bucket',
  production_round_ingredient_issues: 'Ingredient issue',
  production_round_packing_entries: 'Packing entry',
  production_sku_packing_verifications: 'Packing verification',
  production_sku_packing_verification_sources: 'Packing source',
  production_round_handling_events: 'Handling event',
  intermediate_lots: 'Intermediate lot',
  transformations: 'Transformation',
  transformation_inputs: 'Transformation input',
  transformation_outputs: 'Transformation output',
  intermediate_stock_movements: 'Intermediate movement',
  inventory_items: 'Inventory item',
  inventory_lots: 'Inventory lot',
  inventory_movements: 'Inventory movement',
  corrections: 'Correction',
  correction: 'Correction',
};

export function activityEntityLabel(entityType: string): string {
  return ACTIVITY_ENTITY_LABELS[entityType] ?? entityType.replaceAll('_', ' ');
}

export function activityActionLabel(action: string): string {
  switch (action) {
    case 'insert':
      return 'Created';
    case 'update':
      return 'Updated';
    case 'delete':
      return 'Deleted';
    default:
      return action.replaceAll('_', ' ');
  }
}

export function summarizeActivityChange(change: ActivityFieldChange): string {
  if (change.field === 'record') return 'Full record';
  return `${change.field.replaceAll('_', ' ')}: ${formatActivityValue(change.from)} → ${formatActivityValue(change.to)}`;
}

export function formatActivityValue(value: unknown): string {
  if (value === null || value === undefined) return 'blank';
  if (typeof value === 'string') return value || 'blank';
  if (typeof value === 'number' || typeof value === 'boolean') return String(value);
  return JSON.stringify(value);
}
