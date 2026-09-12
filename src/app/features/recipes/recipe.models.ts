export interface RecipeComponent {
  id: string;
  ingredient_id: string | null;
  material_product_id: string | null;
  uom_id: string;
  quantity: number;
  tolerance_min: number | null;
  tolerance_max: number | null;
  sequence: number | null;
  units_of_measure: { code: string } | null;
  ingredients: { name: string; addition_stage: IngredientAdditionStage | null } | null;
  products: { name: string } | null;
}

export interface RecipeVersion {
  id: string;
  version_number: number;
  basis_quantity: number;
  basis_uom_id: string;
  effective_from: string;
  effective_to: string | null;
  units_of_measure: { code: string } | null;
  recipe_components: RecipeComponent[];
}

export interface RecipeSummary {
  id: string;
  product_id: string;
  name: string;
  confidential: boolean;
  active: boolean;
  products: { name: string; code: string } | null;
  recipe_versions: RecipeVersion[];
}

export interface RecipeProductOption {
  id: string;
  code: string;
  name: string;
  product_type: 'raw' | 'intermediate' | 'finished';
}

export interface RecipeIngredientOption {
  id: string;
  code: string;
  name: string;
  default_uom_id: string;
  addition_stage: IngredientAdditionStage | null;
}

export interface RecipeUnitOption {
  id: string;
  code: string;
  name: string;
}

export type RecipeComponentType = 'ingredient' | 'product';
export type IngredientAdditionStage = 'processing_vat' | 'coagulation';

export function validToleranceRange(min: number | null, max: number | null): boolean {
  return min === null || max === null || min <= max;
}

export interface ScalableComponent {
  quantity: number;
  toleranceMin?: number | null;
  toleranceMax?: number | null;
}

export interface ScaledComponent {
  quantity: number;
  toleranceMin: number | null;
  toleranceMax: number | null;
}

export function scaleComponent(
  component: ScalableComponent,
  basisQuantity: number,
  requestedQuantity: number,
): ScaledComponent {
  if (basisQuantity <= 0 || requestedQuantity <= 0) {
    throw new Error('Recipe basis and requested quantity must be positive.');
  }
  const factor = requestedQuantity / basisQuantity;
  return {
    quantity: component.quantity * factor,
    toleranceMin:
      component.toleranceMin === null || component.toleranceMin === undefined
        ? null
        : component.toleranceMin * factor,
    toleranceMax:
      component.toleranceMax === null || component.toleranceMax === undefined
        ? null
        : component.toleranceMax * factor,
  };
}
