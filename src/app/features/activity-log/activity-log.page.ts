import { DatePipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { RouterLink } from '@angular/router';
import { NavigationRailComponent } from '../../shared/navigation-rail/navigation-rail.component';
import {
  activityActionLabel,
  activityEntityLabel,
  summarizeActivityChange,
  type ActivityEvent,
} from './activity-log.models';
import { ActivityLogService } from './activity-log.service';

@Component({
  selector: 'app-activity-log-page',
  imports: [DatePipe, RouterLink, NavigationRailComponent],
  templateUrl: './activity-log.page.html',
})
export class ActivityLogPage implements OnInit {
  private readonly activityLog = inject(ActivityLogService);
  readonly events = signal<ActivityEvent[]>([]);
  readonly loading = signal(true);
  readonly errorMessage = signal<string | null>(null);
  readonly entityFilter = signal('all');

  readonly entityOptions = computed(() => {
    const entities = new Set(this.events().map((event) => event.entity_type));
    return [...entities].sort().map((entity) => ({
      value: entity,
      label: activityEntityLabel(entity),
    }));
  });
  readonly filteredEvents = computed(() =>
    this.events().filter(
      (event) => this.entityFilter() === 'all' || event.entity_type === this.entityFilter(),
    ),
  );

  async ngOnInit(): Promise<void> {
    await this.load();
  }

  async load(): Promise<void> {
    this.loading.set(true);
    this.errorMessage.set(null);
    try {
      this.events.set(await this.activityLog.listRecent());
    } catch (error) {
      this.errorMessage.set(
        error instanceof Error ? error.message : 'Unable to load the activity log.',
      );
    } finally {
      this.loading.set(false);
    }
  }

  setEntityFilter(value: string): void {
    this.entityFilter.set(value);
  }

  entityLabel(entityType: string): string {
    return activityEntityLabel(entityType);
  }

  actionLabel(action: string): string {
    return activityActionLabel(action);
  }

  changeSummary(event: ActivityEvent): string[] {
    return event.changed_fields.slice(0, 5).map(summarizeActivityChange);
  }

  hiddenChangeCount(event: ActivityEvent): number {
    return Math.max(event.changed_fields.length - 5, 0);
  }
}
