import { Injectable, computed, inject, signal } from '@angular/core';
import type { Session } from '@supabase/supabase-js';
import { SupabaseService } from '../../services/supabase.services';
import type { AppRole, ImpersonationProfile, Profile } from './auth.models';

@Injectable({ providedIn: 'root' })
export class AuthService {
  private readonly supabaseService = inject(SupabaseService);
  private readonly sessionState = signal<Session | null>(null);
  private readonly profileState = signal<Profile | null>(null);
  private readonly impersonatedProfileState = signal<ImpersonationProfile | null>(null);
  private initialization: Promise<void> | null = null;
  private readonly impersonationStorageKey = 'production-dairy-impersonated-profile';

  readonly session = this.sessionState.asReadonly();
  readonly actualProfile = this.profileState.asReadonly();
  readonly impersonatedProfile = this.impersonatedProfileState.asReadonly();
  readonly profile = computed(() => this.impersonatedProfileState() ?? this.profileState());
  readonly user = computed(() => this.sessionState()?.user ?? null);
  readonly isAuthenticated = computed(
    () => this.user() !== null && this.profileState()?.active === true,
  );
  readonly canImpersonate = computed(
    () =>
      this.profileState()?.active === true &&
      (this.profileState()?.role === 'owner' || this.profileState()?.role === 'admin'),
  );
  readonly isImpersonating = computed(() => this.impersonatedProfileState() !== null);

  constructor() {
    this.supabaseService.client.auth.onAuthStateChange((_event, session) => {
      this.sessionState.set(session);
      queueMicrotask(() => void this.loadProfile(session));
    });
  }

  initialize(): Promise<void> {
    if (!this.initialization) this.initialization = this.restoreSession();
    return this.initialization;
  }

  async signIn(email: string, password: string): Promise<void> {
    const { data, error } = await this.supabaseService.client.auth.signInWithPassword({
      email,
      password,
    });
    if (error) throw error;

    const profileError = await this.loadProfile(data.session);
    if (profileError) {
      await this.signOut();
      throw new Error(`Unable to load your application profile: ${profileError}`);
    }
    if (!this.profileState()?.active) {
      const status = this.profileState()?.approval_status;
      await this.signOut();
      throw new Error(
        status === 'disapproved'
          ? 'Your account has been disapproved by the owner.'
          : 'Your account is awaiting activation by an owner.',
      );
    }
  }

  async signUp(
    email: string,
    password: string,
    displayName: string,
  ): Promise<'ready' | 'confirmation_required'> {
    const { data, error } = await this.supabaseService.client.auth.signUp({
      email,
      password,
      options: { data: { display_name: displayName.trim() } },
    });
    if (error) throw error;

    if (data.session) {
      await this.signOut();
      return 'ready';
    }
    return 'confirmation_required';
  }

  async signOut(): Promise<void> {
    const { error } = await this.supabaseService.client.auth.signOut();
    if (error) throw error;
    this.sessionState.set(null);
    this.profileState.set(null);
    this.clearImpersonation();
  }

  hasRole(...roles: AppRole[]): boolean {
    const profile = this.profile();
    return profile?.active === true && roles.includes(profile.role);
  }

  hasActualRole(...roles: AppRole[]): boolean {
    const profile = this.profileState();
    return profile?.active === true && roles.includes(profile.role);
  }

  async listImpersonatableWorkers(): Promise<ImpersonationProfile[]> {
    const { data, error } = await this.supabaseService.client.rpc('list_impersonatable_workers');
    if (error) throw error;
    return data as ImpersonationProfile[];
  }

  startImpersonation(profile: ImpersonationProfile): void {
    if (!this.canImpersonate() || profile.role !== 'factory_worker' || !profile.active) return;
    this.impersonatedProfileState.set(profile);
    this.storeImpersonation(profile);
  }

  stopImpersonation(): void {
    this.clearImpersonation();
  }

  private async restoreSession(): Promise<void> {
    const { data, error } = await this.supabaseService.client.auth.getSession();
    if (error) throw error;
    this.sessionState.set(data.session);
    await this.loadProfile(data.session);
  }

  private async loadProfile(session: Session | null): Promise<string | null> {
    if (!session) {
      this.profileState.set(null);
      return null;
    }

    const { data, error } = await this.supabaseService.client
      .from('profiles')
      .select('id, display_name, role, active, approval_status')
      .eq('id', session.user.id)
      .single<Profile>();

    this.profileState.set(error ? null : data);
    if (data && !this.impersonatedProfileState()) this.restoreImpersonation();
    if (!this.canImpersonate()) this.clearImpersonation();
    return error?.message ?? null;
  }

  private restoreImpersonation(): void {
    try {
      if (typeof sessionStorage === 'undefined') return;
      const stored = sessionStorage.getItem(this.impersonationStorageKey);
      if (!stored) return;
      const profile = JSON.parse(stored) as ImpersonationProfile;
      if (profile.role === 'factory_worker' && profile.active) {
        this.impersonatedProfileState.set(profile);
      }
    } catch {
      this.clearImpersonation();
    }
  }

  private storeImpersonation(profile: ImpersonationProfile): void {
    try {
      if (typeof sessionStorage === 'undefined') return;
      sessionStorage.setItem(this.impersonationStorageKey, JSON.stringify(profile));
    } catch {
      // Session storage is a convenience only; impersonation still works for this tab.
    }
  }

  private clearImpersonation(): void {
    this.impersonatedProfileState.set(null);
    try {
      if (typeof sessionStorage === 'undefined') return;
      sessionStorage.removeItem(this.impersonationStorageKey);
    } catch {
      // Ignore storage failures in restricted browser contexts.
    }
  }
}
