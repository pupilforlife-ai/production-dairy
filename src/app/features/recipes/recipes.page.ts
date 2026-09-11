import { Component, OnInit, inject, signal } from '@angular/core';
import { FormArray, FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  scaleComponent,
  validToleranceRange,
  type RecipeComponentType,
  type RecipeIngredientOption,
  type IngredientAdditionStage,
  type RecipeProductOption,
  type RecipeSummary,
  type RecipeUnitOption,
  type RecipeVersion,
} from './recipe.models';
import { RecipeService } from './recipe.service';

type RecipeComponentGroup = FormGroup<{
  type: FormControl<RecipeComponentType>;
  materialId: FormControl<string>;
  quantity: FormControl<number | null>;
  uomId: FormControl<string>;
  toleranceMin: FormControl<number | null>;
  toleranceMax: FormControl<number | null>;
}>;

@Component({
  selector: 'app-recipes-page',
  imports: [ReactiveFormsModule, RouterLink, NavigationRailComponent],
  templateUrl: './recipes.page.html',
})
export class RecipesPage implements OnInit {
  private readonly recipeService = inject(RecipeService);
  readonly recipes = signal<RecipeSummary[]>([]);
  readonly products = signal<RecipeProductOption[]>([]);
  readonly ingredients = signal<RecipeIngredientOption[]>([]);
  readonly units = signal<RecipeUnitOption[]>([]);
  readonly requestedQuantities = signal<Record<string, number>>({});
  readonly showCreateForm = signal(false);
  readonly newIngredientForIndex = signal<number | null>(null);
  readonly loading = signal(true);
  readonly saving = signal(false);
  readonly savingIngredient = signal(false);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);

  readonly createForm = new FormGroup({
    productId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    basisQuantity: new FormControl<number | null>(null, [
      Validators.required,
      Validators.min(0.001),
    ]),
    basisUomId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    effectiveFrom: new FormControl(this.today(), {
      nonNullable: true,
      validators: [Validators.required],
    }),
    components: new FormArray<RecipeComponentGroup>([this.createComponentGroup()]),
  });

  readonly newIngredientForm = new FormGroup({
    code: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    name: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    uomId: new FormControl('', { nonNullable: true, validators: [Validators.required] }),
    additionStage: new FormControl<IngredientAdditionStage>('processing_vat', {
      nonNullable: true,
      validators: [Validators.required],
    }),
  });

  get components(): FormArray<RecipeComponentGroup> {
    return this.createForm.controls.components;
  }

  async ngOnInit(): Promise<void> {
    await this.load();
    this.createForm.controls.basisUomId.setValue(this.unitId('kg'));
    this.components.at(0).controls.uomId.setValue(this.unitId('kg'));
  }

  toggleCreateForm(): void {
    this.showCreateForm.set(!this.showCreateForm());
    this.newIngredientForIndex.set(null);
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  addComponent(): void {
    this.components.push(this.createComponentGroup());
  }

  removeComponent(index: number): void {
    if (this.components.length > 1) {
      this.components.removeAt(index);
      this.newIngredientForIndex.set(null);
    }
  }

  changeComponentType(index: number, value: string): void {
    const row = this.components.at(index);
    row.controls.type.setValue(value as RecipeComponentType);
    row.controls.materialId.setValue('');
    if (this.newIngredientForIndex() === index) this.newIngredientForIndex.set(null);
  }

  selectComponentMaterial(index: number, materialId: string): void {
    const row = this.components.at(index);
    if (row.controls.type.value !== 'ingredient') return;
    const ingredient = this.ingredients().find((item) => item.id === materialId);
    if (ingredient) row.controls.uomId.setValue(ingredient.default_uom_id);
  }

  openNewIngredient(index: number): void {
    this.newIngredientForIndex.set(index);
    this.newIngredientForm.reset({
      code: '',
      name: '',
      uomId: this.unitId('kg'),
      additionStage: 'processing_vat',
    });
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  cancelNewIngredient(): void {
    this.newIngredientForIndex.set(null);
  }

  async createIngredient(): Promise<void> {
    const targetIndex = this.newIngredientForIndex();
    if (targetIndex === null || this.newIngredientForm.invalid || this.savingIngredient()) {
      this.newIngredientForm.markAllAsTouched();
      return;
    }
    const values = this.newIngredientForm.getRawValue();
    this.savingIngredient.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      const ingredient = await this.recipeService.createIngredient({
        code: values.code,
        name: values.name,
        uomId: values.uomId,
        additionStage: values.additionStage,
      });
      this.ingredients.update((ingredients) =>
        [...ingredients, ingredient].sort((left, right) => left.name.localeCompare(right.name)),
      );
      const targetRow = this.components.at(targetIndex);
      if (targetRow) {
        targetRow.controls.type.setValue('ingredient');
        targetRow.controls.materialId.setValue(ingredient.id);
        targetRow.controls.uomId.setValue(ingredient.default_uom_id);
      }
      this.newIngredientForIndex.set(null);
      this.successMessage.set(`${ingredient.name} was added and selected in the recipe.`);
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to add ingredient.');
    } finally {
      this.savingIngredient.set(false);
    }
  }

  availableProductComponents(): RecipeProductOption[] {
    const recipeProductId = this.createForm.controls.productId.value;
    return this.products().filter((product) => product.id !== recipeProductId);
  }

  async createRecipe(): Promise<void> {
    if (this.createForm.invalid || this.saving()) {
      this.createForm.markAllAsTouched();
      return;
    }
    const values = this.createForm.getRawValue();
    const invalidTolerance = values.components.some(
      (component) => !validToleranceRange(component.toleranceMin, component.toleranceMax),
    );
    if (invalidTolerance) {
      this.errorMessage.set('A minimum tolerance cannot be greater than its maximum.');
      return;
    }
    const componentKeys = values.components.map(
      (component) => `${component.type}:${component.materialId}`,
    );
    if (new Set(componentKeys).size !== componentKeys.length) {
      this.errorMessage.set('The same component cannot be added twice.');
      return;
    }
    if (values.basisQuantity === null) return;

    this.saving.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.recipeService.createRecipe({
        productId: values.productId,
        name: values.name,
        basisQuantity: values.basisQuantity,
        basisUomId: values.basisUomId,
        effectiveFrom: values.effectiveFrom,
        components: values.components.map((component) => ({
          type: component.type,
          materialId: component.materialId,
          quantity: Number(component.quantity),
          uomId: component.uomId,
          toleranceMin: component.toleranceMin,
          toleranceMax: component.toleranceMax,
        })),
      });
      this.successMessage.set(`${values.name.trim()} was created as Version 1.`);
      this.resetCreateForm();
      this.showCreateForm.set(false);
      await this.load(false);
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to create recipe.');
    } finally {
      this.saving.set(false);
    }
  }

  currentVersion(recipe: RecipeSummary): RecipeVersion | undefined {
    return [...recipe.recipe_versions].sort((a, b) => b.version_number - a.version_number)[0];
  }

  updateRequestedQuantity(recipeId: string, event: Event): void {
    const value = Number((event.target as HTMLInputElement).value);
    if (Number.isFinite(value) && value > 0) {
      this.requestedQuantities.update((quantities) => ({ ...quantities, [recipeId]: value }));
    }
  }

  scaledQuantity(recipe: RecipeSummary, componentQuantity: number): number {
    const version = this.currentVersion(recipe);
    if (!version) return 0;
    return scaleComponent(
      { quantity: componentQuantity },
      version.basis_quantity,
      this.requestedQuantities()[recipe.id] ?? version.basis_quantity,
    ).quantity;
  }

  additionStageLabel(stage: IngredientAdditionStage | null | undefined): string {
    if (stage === 'processing_vat') return 'VAT 2 / VAT 3';
    if (stage === 'coagulation') return 'Coagulation tank';
    return 'Addition stage not configured';
  }

  private async load(showLoader = true): Promise<void> {
    if (showLoader) this.loading.set(true);
    try {
      const data = await this.recipeService.load();
      this.recipes.set(data.recipes);
      this.products.set(data.products);
      this.ingredients.set(data.ingredients);
      this.units.set(data.units);
      this.requestedQuantities.set(
        Object.fromEntries(
          data.recipes.map((recipe) => {
            const version = this.currentVersion(recipe);
            return [recipe.id, version?.basis_quantity ?? 1];
          }),
        ),
      );
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to load recipes.');
    } finally {
      this.loading.set(false);
    }
  }

  private resetCreateForm(): void {
    this.createForm.reset({
      productId: '',
      name: '',
      basisQuantity: null,
      basisUomId: this.unitId('kg'),
      effectiveFrom: this.today(),
    });
    this.components.clear();
    this.components.push(this.createComponentGroup());
    this.newIngredientForIndex.set(null);
  }

  private createComponentGroup(): RecipeComponentGroup {
    return new FormGroup({
      type: new FormControl<RecipeComponentType>('ingredient', { nonNullable: true }),
      materialId: new FormControl('', {
        nonNullable: true,
        validators: [Validators.required],
      }),
      quantity: new FormControl<number | null>(null, [Validators.required, Validators.min(0.001)]),
      uomId: new FormControl(this.unitId('kg'), {
        nonNullable: true,
        validators: [Validators.required],
      }),
      toleranceMin: new FormControl<number | null>(null, [Validators.min(0)]),
      toleranceMax: new FormControl<number | null>(null, [Validators.min(0)]),
    });
  }

  private unitId(code: string): string {
    return this.units().find((unit) => unit.code === code)?.id ?? '';
  }

  private today(): string {
    return new Date().toISOString().slice(0, 10);
  }
}
