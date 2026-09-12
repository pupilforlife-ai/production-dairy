import { inject } from '@angular/core';
import type { CanActivateFn } from '@angular/router';
import { Router } from '@angular/router';
import { environment } from '../../../environment';
import { AuthService } from './auth.service';
import type { AppRole } from './auth.models';

export const authGuard: CanActivateFn = async (_route, state) => {
  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.initialize();
  return auth.isAuthenticated()
    ? true
    : router.createUrlTree(['/login'], { queryParams: { returnUrl: state.url } });
};

export const guestGuard: CanActivateFn = async () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.initialize();
  return auth.isAuthenticated() ? router.createUrlTree(['/']) : true;
};

export const roleGuard = (...roles: AppRole[]): CanActivateFn => {
  return async () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    await auth.initialize();
    return auth.hasRole(...roles) ? true : router.createUrlTree(['/']);
  };
};

export const actualRoleGuard = (...roles: AppRole[]): CanActivateFn => {
  return async () => {
    const auth = inject(AuthService);
    const router = inject(Router);
    await auth.initialize();
    return auth.hasActualRole(...roles) ? true : router.createUrlTree(['/']);
  };
};

/**
 * Pages protected by this guard remain available during normal development,
 * but cannot be opened in the restricted beta release.
 */
export const fullReleaseGuard: CanActivateFn = () => {
  const router = inject(Router);
  return environment.betaMode ? router.createUrlTree(['/production-board']) : true;
};

/**
 * Supporting beta pages are owner-only. Their existing access rules continue
 * to apply when beta mode is disabled.
 */
export const betaOwnerGuard: CanActivateFn = async () => {
  if (!environment.betaMode) {
    return true;
  }

  const auth = inject(AuthService);
  const router = inject(Router);
  await auth.initialize();
  return auth.hasRole('owner') ? true : router.createUrlTree(['/production-board']);
};

/** Send every authenticated beta user to the only public beta workspace. */
export const betaLandingGuard: CanActivateFn = () => {
  const router = inject(Router);
  return environment.betaMode ? router.createUrlTree(['/production-board']) : true;
};
