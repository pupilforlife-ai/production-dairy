import { describe, expect, it } from 'vitest';
import { balanceKey, totalBalanceForItem, type InventoryBalance } from './inventory.models';

const balances = [
  {
    inventory_item_id: 'oil',
    inventory_lot_id: 'lot-1',
    storage_location_id: 'bulk',
    current_quantity: 80,
  },
  {
    inventory_item_id: 'oil',
    inventory_lot_id: 'lot-1',
    storage_location_id: 'intermediate',
    current_quantity: 20,
  },
] as InventoryBalance[];

describe('inventory helpers', () => {
  it('creates a stable lot and location key', () => {
    expect(balanceKey(balances[0]!)).toBe('lot-1|bulk');
  });

  it('totals stock across locations without editing balances', () => {
    expect(totalBalanceForItem(balances, 'oil')).toBe(100);
  });
});
