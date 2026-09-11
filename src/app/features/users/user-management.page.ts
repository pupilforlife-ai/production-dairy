import { DatePipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import type { AppRole, ApprovalStatus } from '../../core/auth/auth.models';
import { AuthService } from '../../core/auth/auth.service';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  USER_ROLES,
  USER_STATUSES,
  countUsersByStatus,
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
  readonly drafts = signal<Record<string, UserDraft>>({});
  readonly loading = signal(true);
  readonly savingUserId = signal<string | null>(null);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly statusFilter = signal<ApprovalStatus | 'all'>('all');

  readonly counts = computed(() => countUsersByStatus(this.users()));
  readonly filteredUsers = computed(() =>
    this.users().filter(
      (user) => this.statusFilter() === 'all' || user.approval_status === this.statusFilter(),
    ),
  );

  async ngOnInit(): Promise<void> {
    await this.load();
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
    if (!this.hasChanges(user) || this.savingUserId()) return;
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

  private updateDraft(user: ManagedUser, change: Partial<UserDraft>): void {
    this.drafts.update((drafts) => ({
      ...drafts,
      [user.id]: { ...this.draftFor(user), ...change },
    }));
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  private async load(showLoader = true): Promise<void> {
    if (showLoader) this.loading.set(true);
    try {
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
}
