import { Routes } from '@angular/router';
import {
  actualRoleGuard,
  authGuard,
  betaLandingGuard,
  fullReleaseGuard,
  guestGuard,
  roleGuard,
} from './core/auth/auth.guard';

export const routes: Routes = [
  {
    path: 'login',
    canActivate: [guestGuard],
    loadComponent: () => import('./features/auth/login.page').then((page) => page.LoginPage),
  },
  {
    path: 'dashboard',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/dashboard/dashboard.page').then((page) => page.DashboardPage),
  },
  {
    path: 'reset-password',
    loadComponent: () =>
      import('./features/auth/reset-password.page').then((page) => page.ResetPasswordPage),
  },
  {
    path: 'master-data',
    canActivate: [authGuard, roleGuard('owner')],
    loadComponent: () =>
      import('./features/master-data/master-data.page').then((page) => page.MasterDataPage),
  },
  {
    path: 'recipes',
    canActivate: [authGuard, roleGuard('owner')],
    loadComponent: () => import('./features/recipes/recipes.page').then((page) => page.RecipesPage),
  },
  {
    path: 'receiving',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/receiving/receiving.page').then((page) => page.ReceivingPage),
  },
  {
    path: 'production-board',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/production-board/production-board.page').then(
        (page) => page.ProductionBoardPage,
      ),
  },
  {
    path: 'intermediate-stock',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/intermediate-stock/intermediate-stock.page').then(
        (page) => page.IntermediateStockPage,
      ),
  },
  {
    path: 'packing',
    canActivate: [authGuard, fullReleaseGuard],
    loadComponent: () => import('./features/packing/packing.page').then((page) => page.PackingPage),
  },
  {
    path: 'packing-verification',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/packing-verification/packing-verification.page').then(
        (page) => page.PackingVerificationPage,
      ),
  },
  {
    path: 'inventory',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/inventory/inventory.page').then((page) => page.InventoryPage),
  },
  {
    path: 'transformations',
    canActivate: [authGuard],
    loadComponent: () =>
      import('./features/transformations/transformation.page').then(
        (page) => page.TransformationPage,
      ),
  },
  {
    path: 'users',
    canActivate: [authGuard, actualRoleGuard('owner', 'admin')],
    loadComponent: () =>
      import('./features/users/user-management.page').then((page) => page.UserManagementPage),
  },
  {
    path: 'activity-log',
    canActivate: [authGuard, actualRoleGuard('owner', 'admin')],
    loadComponent: () =>
      import('./features/activity-log/activity-log.page').then((page) => page.ActivityLogPage),
  },
  {
    path: '',
    pathMatch: 'full',
    canActivate: [authGuard, betaLandingGuard],
    loadComponent: () =>
      import('./features/dashboard/dashboard.page').then((page) => page.DashboardPage),
  },
  { path: '**', redirectTo: '' },
];
