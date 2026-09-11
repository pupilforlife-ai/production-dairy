import type { Session, User } from '@supabase/supabase-js';

export type AppRole = 'owner' | 'admin' | 'factory_worker';
export type ApprovalStatus = 'pending' | 'approved' | 'disapproved';

export interface Profile {
  id: string;
  display_name: string;
  role: AppRole;
  active: boolean;
  approval_status: ApprovalStatus;
}

export interface AuthState {
  session: Session | null;
  user: User | null;
  profile: Profile | null;
}
