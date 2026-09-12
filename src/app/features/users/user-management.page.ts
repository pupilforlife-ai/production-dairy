import { DatePipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { AppRole, ApprovalStatus, ImpersonationProfile } from '../../core/auth/auth.models';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  USER_ROLES,
  USER_STATUSES,
  countUsersByStatus,
  validatePasswordReset,
  type ManagedUser,
  type UserDraft,
} from './user-management.models';
import { UserManagementService } from './user-management.service';

@Component({
  selector: 'app-user-management-page',
  imports: [DatePipe, RouterLink, NavigationRailComponent],
  templateUrl: './user-management.page.html',
})
export class UserManagementPage implements OnInit {
  private readonly userManagement = inject(UserManagementService);
  readonly auth = inject(AuthService);
  readonly roles = USER_ROLES;
  readonly statuses = USER_STATUSES;
  readonly users = signal<ManagedUser[]>([]);
  readonly workers = signal<ImpersonationProfile[]>([]);
  readonly drafts = signal<Record<string, UserDraft>>({});
  readonly loading = signal(true);
  readonly loadingWorkers = signal(true);
  readonly savingUserId = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly statusFilter = signal<ApprovalStatus | 'all'>('all');
  readonly passwordUserId = signal<string | null>(null);
  readonly deleteUserId = signal<string | null>(null);
  readonly newPassword = signal('');
  readonly passwordConfirmation = signal('');
  readonly actionUserId = signal<string | null>(null);

  readonly counts = computed(() => countUsersByStatus(this.users()));
  readonly canManageUsers = computed(() => this.auth.hasActualRole('owner'));
  readonly filteredUsers = computed(() =>
    this.users().filter(
      (user) => this.statusFilter() === 'all' || user.approval_status === this.statusFilter(),
    ),
  );

  async ngOnInit(): Promise<void> {
    await Promise.all([this.load(), this.loadWorkers()]);
  }

  setFilter(value: string): void {
    this.statusFilter.set(value as ApprovalStatus | 'all');
  }

  draftFor(user: ManagedUser): UserDraft {
    return this.drafts()[user.id] ?? { role: user.role, status: user.approval_status };
  }

  setRole(user: ManagedUser, value: string): void {
    this.updateDraft(user, { role: value as AppRole });
  }

  setStatus(user: ManagedUser, value: string): void {
    this.updateDraft(user, { status: value as ApprovalStatus });
  }

  hasChanges(user: ManagedUser): boolean {
    const draft = this.draftFor(user);
    return draft.role !== user.role || draft.status !== user.approval_status;
  }

  isCurrentUser(user: ManagedUser): boolean {
    return user.id === this.auth.user()?.id;
  }

  statusLabel(status: ApprovalStatus | 'all'): string {
    if (status === 'all') return 'All registered users';
    return USER_STATUSES.find((option) => option.value === status)?.label ?? status;
  }

  async save(user: ManagedUser): Promise<void> {
    if (!this.canManageUsers() || !this.hasChanges(user) || this.savingUserId()) return;
    const draft = this.draftFor(user);
    this.savingUserId.set(user.id);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.userManagement.updateUser(user.id, draft.status, draft.role);
      this.successMessage.set(`${user.display_name || user.email} was updated.`);
      await this.load(false);
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to update the user.');
    } finally {
      this.savingUserId.set(null);
    }
  }

  openPasswordReset(user: ManagedUser): void {
    if (!this.canManageUsers()) return;
    this.deleteUserId.set(null);
    this.passwordUserId.set(user.id);
    this.newPassword.set('');
    this.passwordConfirmation.set('');
    this.clearMessages();
  }

  confirmDelete(user: ManagedUser): void {
    if (!this.canManageUsers()) return;
    if (this.isCurrentUser(user)) return;
    this.passwordUserId.set(null);
    this.deleteUserId.set(user.id);
    this.clearPasswords();
    this.clearMessages();
  }

  cancelOwnerAction(): void {
    this.passwordUserId.set(null);
    this.deleteUserId.set(null);
    this.clearPasswords();
  }

  async resetPassword(user: ManagedUser): Promise<void> {
    if (!this.canManageUsers() || this.actionUserId()) return;
    const validationError = validatePasswordReset(this.newPassword(), this.passwordConfirmation());
    if (validationError) {
      this.errorMessage.set(validationError);
      return;
    }

    this.actionUserId.set(user.id);
    this.clearMessages();
    try {
      await this.userManagement.resetPassword(user.id, this.newPassword());
      this.successMessage.set(`Password changed for ${user.display_name || user.email}.`);
      this.passwordUserId.set(null);
      this.clearPasswords();
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to change the user password.',
      );
    } finally {
      this.actionUserId.set(null);
    }
  }

  async deleteUser(user: ManagedUser): Promise<void> {
    if (!this.canManageUsers() || this.isCurrentUser(user) || this.actionUserId()) return;
    this.actionUserId.set(user.id);
    this.clearMessages();
    try {
      await this.userManagement.deleteUser(user.id);
      this.successMessage.set(`${user.display_name || user.email} was permanently deleted.`);
      this.deleteUserId.set(null);
      await this.load(false);
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to delete the user.');
    } finally {
      this.actionUserId.set(null);
    }
  }

  private updateDraft(user: ManagedUser, change: Partial<UserDraft>): void {
    this.drafts.update((drafts) => ({
      ...drafts,
      [user.id]: { ...this.draftFor(user), ...change },
    }));
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  private clearPasswords(): void {
    this.newPassword.set('');
    this.passwordConfirmation.set('');
  }

  private clearMessages(): void {
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  private async load(showLoader = true): Promise<void> {
    if (showLoader) this.loading.set(true);
    try {
      if (!this.canManageUsers()) {
        this.users.set([]);
        this.drafts.set({});
        return;
      }
      const users = await this.userManagement.listUsers();
      this.users.set(users);
      this.drafts.set(
        Object.fromEntries(
          users.map((user) => [
            user.id,
            { role: user.role, status: user.approval_status } satisfies UserDraft,
          ]),
        ),
      );
    } catch (error) {
      this.errorMessage.set(error instanceof Error ? error.message : 'Unable to load users.');
    } finally {
      this.loading.set(false);
    }
  }

  selectWorker(value: string): void {
    if (!value) {
      this.auth.stopImpersonation();
      this.successMessage.set('Returned to your actual role.');
      this.errorMessage.set(null);
      return;
    }
    const worker = this.workers().find((candidate) => candidate.id === value);
    if (!worker) return;
    this.auth.startImpersonation(worker);
    this.successMessage.set(`Now viewing as ${worker.display_name || worker.email}.`);
    this.errorMessage.set(null);
  }

  async refreshWorkers(): Promise<void> {
    await this.loadWorkers();
  }

  private async loadWorkers(): Promise<void> {
    this.loadingWorkers.set(true);
    try {
      const workers = await this.auth.listImpersonatableWorkers();
      this.workers.set(workers);
      const activeWorkerId = this.auth.impersonatedProfile()?.id;
      if (activeWorkerId && !workers.some((worker) => worker.id === activeWorkerId)) {
        this.auth.stopImpersonation();
      }
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to load factory workers.',
      );
    } finally {
      this.loadingWorkers.set(false);
    }
  }
}
