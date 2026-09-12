export type InventoryItemType = 'ingredient' | 'packaging';

export interface InventoryItem {
  id: string;
  item_type: InventoryItemType;
  code: string;
  name: string;
  default_uom_id: string;
  active: boolean;
  units_of_measure: { code: string } | null;
}

export interface InventoryBalance {
  inventory_item_id: string;
  item_type: InventoryItemType;
  item_code: string;
  item_name: string;
  inventory_lot_id: string;
  lot_code: string;
  received_at: string;
  expiry_date: string | null;
  storage_location_id: string;
  location_code: string;
  location_name: string;
  uom_id: string;
  uom_code: string;
  current_quantity: number;
}

export interface InventoryLocation {
  id: string;
  code: string;
  name: string;
}

export interface InventoryUnit {
  id: string;
  code: string;
  name: string;
}

export interface InventoryReference {
  id: string;
  label: string;
}

export interface InventoryMovementSummary {
  id: string;
  movement_type: 'receive' | 'transfer' | 'consume' | 'adjustment_in' | 'adjustment_out';
  quantity: number;
  reason: string | null;
  notes: string | null;
  occurred_at: string;
  inventory_items: { code: string; name: string; item_type: InventoryItemType } | null;
  inventory_lots: { lot_code: string } | null;
  units_of_measure: { code: string } | null;
  source_location: { name: string } | null;
  destination_location: { name: string } | null;
  production_batches: { batch_code: string } | null;
  packing_runs: { id: string; skus: { code: string } | null } | null;
}

export interface InventoryUsageSummary {
  inventory_item_id: string;
  item_code: string;
  item_name: string;
  source_lot_id: string;
  source_lot_code: string;
  round_count: number;
  d_rounds: number;
  cs_rounds: number;
  total_quantity: number;
  uom_code: string;
  last_used_at: string;
}

export interface InventoryData {
  items: InventoryItem[];
  balances: InventoryBalance[];
  locations: InventoryLocation[];
  units: InventoryUnit[];
  productionReferences: InventoryReference[];
  packingReferences: InventoryReference[];
  movements: InventoryMovementSummary[];
  usageSummaries: InventoryUsageSummary[];
}

export function balanceKey(balance: InventoryBalance): string {
  return balance.inventory_lot_id + '|' + balance.storage_location_id;
}

export function totalBalanceForItem(balances: InventoryBalance[], inventoryItemId: string): number {
  return balances
    .filter((balance) => balance.inventory_item_id === inventoryItemId)
    .reduce((total, balance) => total + Number(balance.current_quantity), 0);
}
