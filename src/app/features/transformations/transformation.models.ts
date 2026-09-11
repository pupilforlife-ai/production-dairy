export type TransformationType =
  | 'cutting'
  | 'blending'
  | 'filling'
  | 'coating'
  | 'frying'
  | 'cooking'
  | 'churning'
  | 'ghee_cooking'
  | 'freezing';

export interface ProcessControlPreset {
  code: string;
  label: string;
  uomLabel: string;
  targetValue: number | null;
  minValue: number | null;
  maxValue: number | null;
}

export interface ProcessTemplate {
  key: string;
  name: string;
  productLine: string;
  type: TransformationType;
  description: string;
  controls: ProcessControlPreset[];
}

export const PROCESS_TEMPLATES: ProcessTemplate[] = [
  {
    key: 'halloumi-production',
    name: 'Halloumi production / cooking',
    productLine: 'Halloumi',
    type: 'cooking',
    description: 'Convert configured inputs into a traceable raw Halloumi lot.',
    controls: [
      {
        code: 'COOK_TEMP',
        label: 'Cooking temperature',
        uomLabel: '°C',
        targetValue: null,
        minValue: null,
        maxValue: null,
      },
      {
        code: 'COOK_TIME',
        label: 'Cooking time',
        uomLabel: 'min',
        targetValue: null,
        minValue: null,
        maxValue: null,
      },
    ],
  },
  {
    key: 'halloumi-cutting',
    name: 'Halloumi cutting',
    productLine: 'Halloumi',
    type: 'cutting',
    description: 'Cut raw Halloumi into vacuum-pack or popper input stock.',
    controls: [],
  },
  {
    key: 'spp-coating',
    name: 'SPP coating',
    productLine: 'SPP',
    type: 'coating',
    description: 'Combine cut paneer and configured coating ingredients.',
    controls: [],
  },
  {
    key: 'spp-frying',
    name: 'SPP flash frying',
    productLine: 'SPP',
    type: 'frying',
    description: 'Record the documented flash-fry controls before refreezing.',
    controls: [
      {
        code: 'FRY_TEMP',
        label: 'Frying temperature',
        uomLabel: '°C',
        targetValue: 185,
        minValue: null,
        maxValue: null,
      },
      {
        code: 'FRY_TIME',
        label: 'Frying time',
        uomLabel: 'sec',
        targetValue: 20,
        minValue: null,
        maxValue: null,
      },
    ],
  },
  {
    key: 'jp-filling-mix',
    name: 'JP filling preparation',
    productLine: 'Jalapeño Poppers',
    type: 'blending',
    description: 'Prepare cream-cheese filling from PAN111 and configured ingredients.',
    controls: [],
  },
  {
    key: 'jp-filling',
    name: 'JP filling',
    productLine: 'Jalapeño Poppers',
    type: 'filling',
    description: 'Fill jalapeños while retaining the filling-lot genealogy.',
    controls: [],
  },
  {
    key: 'jp-coating',
    name: 'JP coating',
    productLine: 'Jalapeño Poppers',
    type: 'coating',
    description: 'Apply configured coating ingredients to filled poppers.',
    controls: [],
  },
  {
    key: 'jp-frying',
    name: 'JP flash frying',
    productLine: 'Jalapeño Poppers',
    type: 'frying',
    description: 'Record the documented flash-fry controls before freezing.',
    controls: [
      {
        code: 'FRY_TEMP',
        label: 'Frying temperature',
        uomLabel: '°C',
        targetValue: 185,
        minValue: null,
        maxValue: null,
      },
      {
        code: 'FRY_TIME',
        label: 'Frying time',
        uomLabel: 'sec',
        targetValue: 20,
        minValue: null,
        maxValue: null,
      },
    ],
  },
  {
    key: 'butter-churning',
    name: 'Butter churning',
    productLine: 'Butter',
    type: 'churning',
    description: 'Combine one or more internal or purchased cream lots into butter.',
    controls: [],
  },
  {
    key: 'butter-blending',
    name: 'Butter blending',
    productLine: 'Butter',
    type: 'blending',
    description: 'Record pure or configured blended-butter production.',
    controls: [],
  },
  {
    key: 'ghee-cooking',
    name: 'Ghee cooking',
    productLine: 'Ghee',
    type: 'ghee_cooking',
    description: 'Cook butter and configured ingredients using an approved recipe version.',
    controls: [
      {
        code: 'COOK_TEMP',
        label: 'Cooking temperature',
        uomLabel: '°C',
        targetValue: null,
        minValue: null,
        maxValue: null,
      },
    ],
  },
  {
    key: 'freezing',
    name: 'Freezing / refreezing',
    productLine: 'Frozen products',
    type: 'freezing',
    description: 'Record a freezing stage and its traceable output lot.',
    controls: [
      {
        code: 'FREEZER_TEMP',
        label: 'Freezer temperature',
        uomLabel: '°C',
        targetValue: null,
        minValue: null,
        maxValue: null,
      },
    ],
  },
];

export interface TransformationLotOption {
  id: string;
  product_id: string;
  lot_code: string;
  display_label: string | null;
  current_quantity: number;
  uom_id: string;
  produced_at: string;
  products: { code: string; name: string } | null;
  units_of_measure: { code: string } | null;
  storage_locations: { name: string } | null;
}

export interface SourceLotOption {
  id: string;
  lot_type: 'milk' | 'purchased_cream';
  lot_code: string;
  received_quantity: number;
  available_quantity: number;
  uom_id: string;
  status: 'accepted' | 'rejected' | 'closed';
  units_of_measure: { code: string } | null;
}

export interface TransformationInventoryBalance {
  inventory_item_id: string;
  inventory_lot_id: string;
  item_code: string;
  item_name: string;
  lot_code: string;
  storage_location_id: string;
  location_name: string;
  current_quantity: number;
  uom_id: string;
  uom_code: string;
}

export interface TransformationProduct {
  id: string;
  code: string;
  name: string;
}

export interface TransformationUnit {
  id: string;
  code: string;
  name: string;
}

export interface TransformationLocation {
  id: string;
  code: string;
  name: string;
}

export interface RecipeVersionOption {
  id: string;
  version_number: number;
  recipes: { name: string; products: { name: string } | null } | null;
}

export interface TransformationHistory {
  id: string;
  transformation_type: TransformationType;
  process_template: string;
  occurred_at: string;
  performed_by: string;
  notes: string | null;
  recipe_versions: {
    version_number: number;
    recipes: { name: string } | null;
  } | null;
  transformation_inputs: Array<{
    quantity: number;
    standard_quantity: number | null;
    variance_quantity: number | null;
    intermediate_lots: {
      lot_code: string;
      products: { name: string } | null;
      units_of_measure: { code: string } | null;
    } | null;
  }>;
  transformation_source_lot_inputs: Array<{
    quantity: number;
    source_lots: { lot_code: string; lot_type: string } | null;
    units_of_measure: { code: string } | null;
  }>;
  transformation_inventory_inputs: Array<{
    quantity: number;
    standard_quantity: number | null;
    variance_quantity: number | null;
    inventory_lots: {
      lot_code: string;
      inventory_items: { name: string } | null;
    } | null;
    units_of_measure: { code: string } | null;
  }>;
  transformation_outputs: Array<{
    output_kind: string;
    output_label: string;
    quantity: number;
    products: { name: string } | null;
    units_of_measure: { code: string } | null;
    intermediate_lots: { lot_code: string } | null;
  }>;
  transformation_process_controls: Array<{
    control_label: string;
    numeric_value: number | null;
    text_value: string | null;
    uom_label: string | null;
    in_spec: boolean | null;
  }>;
}

export function processControlInSpec(
  value: number | null,
  min: number | null,
  max: number | null,
): boolean | null {
  if (value === null) return null;
  if (min !== null && value < min) return false;
  if (max !== null && value > max) return false;
  return true;
}
