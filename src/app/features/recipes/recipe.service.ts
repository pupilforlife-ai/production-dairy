import { Injectable, inject } from '@angular/core';
import { SupabaseService } from '../../services/supabase.services';
import type {
  RecipeComponentType,
  RecipeIngredientOption,
  IngredientAdditionStage,
  RecipeProductOption,
  RecipeSummary,
  RecipeUnitOption,
} from './recipe.models';

export interface RecipePageData {
  recipes: RecipeSummary[];
  products: RecipeProductOption[];
  ingredients: RecipeIngredientOption[];
  units: RecipeUnitOption[];
}

@Injectable({ providedIn: 'root' })
export class RecipeService {
  private readonly supabase = inject(SupabaseService).client;

  async listRecipes(): Promise<RecipeSummary[]> {
    const { data, error } = await this.supabase
      .from('recipes')
      .select(
        'id, product_id, name, confidential, active, products(name, code), recipe_versions(id, version_number, basis_quantity, basis_uom_id, effective_from, effective_to, units_of_measure(code), recipe_components(id, ingredient_id, material_product_id, uom_id, quantity, tolerance_min, tolerance_max, sequence, units_of_measure(code), ingredients(name, addition_stage), products(name)))',
      )
      .order('name');
    if (error) throw error;
    return data as unknown as RecipeSummary[];
  }

  async load(): Promise<RecipePageData> {
    const [recipes, productsResult, ingredientsResult, unitsResult] = await Promise.all([
      this.listRecipes(),
      this.supabase
        .from('products')
        .select('id, code, name, product_type')
        .eq('active', true)
        .order('name'),
      this.supabase
        .from('ingredients')
        .select('id, code, name, default_uom_id, addition_stage')
        .eq('active', true)
        .order('name'),
      this.supabase
        .from('units_of_measure')
        .select('id, code, name')
        .eq('active', true)
        .order('code'),
    ]);
    for (const result of [productsResult, ingredientsResult, unitsResult]) {
      if (result.error) throw result.error;
    }
    return {
      recipes,
      products: productsResult.data as RecipeProductOption[],
      ingredients: ingredientsResult.data as RecipeIngredientOption[],
      units: unitsResult.data as RecipeUnitOption[],
    };
  }

  async createRecipe(input: {
    productId: string;
    name: string;
    basisQuantity: number;
    basisUomId: string;
    effectiveFrom: string;
    components: Array<{
      type: RecipeComponentType;
      materialId: string;
      quantity: number;
      uomId: string;
      toleranceMin: number | null;
      toleranceMax: number | null;
    }>;
  }): Promise<string> {
    const { data, error } = await this.supabase.rpc('create_recipe_with_version', {
      requested_product_id: input.productId,
      requested_name: input.name,
      requested_basis_quantity: input.basisQuantity,
      requested_basis_uom_id: input.basisUomId,
      requested_effective_from: input.effectiveFrom,
      requested_components: input.components.map((component) => ({
        type: component.type,
        material_id: component.materialId,
        quantity: component.quantity,
        uom_id: component.uomId,
        tolerance_min: component.toleranceMin,
        tolerance_max: component.toleranceMax,
      })),
    });
    if (error) throw error;
    return data as string;
  }

  async createRecipeVersion(input: {
    recipeId: string;
    basisQuantity: number;
    basisUomId: string;
    effectiveFrom: string;
    components: Array<{
      type: RecipeComponentType;
      materialId: string;
      quantity: number;
      uomId: string;
      toleranceMin: number | null;
      toleranceMax: number | null;
    }>;
  }): Promise<string> {
    const { data, error } = await this.supabase.rpc('create_recipe_next_version', {
      requested_recipe_id: input.recipeId,
      requested_basis_quantity: input.basisQuantity,
      requested_basis_uom_id: input.basisUomId,
      requested_effective_from: input.effectiveFrom,
      requested_components: input.components.map((component) => ({
        type: component.type,
        material_id: component.materialId,
        quantity: component.quantity,
        uom_id: component.uomId,
        tolerance_min: component.toleranceMin,
        tolerance_max: component.toleranceMax,
      })),
    });
    if (error) throw error;
    return data as string;
  }

  async createIngredient(input: {
    code: string;
    name: string;
    uomId: string;
    additionStage: IngredientAdditionStage;
  }): Promise<RecipeIngredientOption> {
    const normalizedCode = input.code.trim().toUpperCase();
    const { error } = await this.supabase.rpc('create_staged_recipe_ingredient', {
      requested_code: normalizedCode,
      requested_name: input.name.trim(),
      requested_uom_id: input.uomId,
      requested_addition_stage: input.additionStage,
    });
    if (error) throw error;

    const { data, error: loadError } = await this.supabase
      .from('ingredients')
      .select('id, code, name, default_uom_id, addition_stage')
      .eq('code', normalizedCode)
      .single();
    if (loadError) throw loadError;
    return data as RecipeIngredientOption;
  }
}
