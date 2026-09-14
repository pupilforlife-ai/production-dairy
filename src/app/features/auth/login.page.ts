import { Component, inject, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';

@Component({
  selector: 'app-login-page',
  imports: [ReactiveFormsModule],
  templateUrl: './login.page.html',
})
export class LoginPage {
  private readonly auth = inject(AuthService);
  private readonly router = inject(Router);
  private readonly route = inject(ActivatedRoute);
  readonly submitting = signal(false);
  readonly mode = signal<'signin' | 'signup' | 'forgot'>('signin');
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly form = new FormGroup({
    displayName: new FormControl('', { nonNullable: true }),
    email: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.email],
    }),
    password: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.minLength(8)],
    }),
    confirmPassword: new FormControl('', { nonNullable: true }),
  });

  async submit(): Promise<void> {
    if (this.submitting() || !this.isCurrentModeValid()) {
      this.form.markAllAsTouched();
      return;
    }
    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      const { displayName, email, password, confirmPassword } = this.form.getRawValue();
      if (this.mode() === 'signup') {
        if (!displayName.trim()) throw new Error('Enter your name.');
        if (password !== confirmPassword) throw new Error('Passwords do not match.');
        const result = await this.auth.signUp(email.trim().toLowerCase(), password, displayName);
        this.successMessage.set(
          result === 'ready'
            ? 'Account created successfully. You can sign in now.'
            : 'Account created. Check your email to confirm the address, then return here to sign in.',
        );
        this.mode.set('signin');
        this.form.patchValue({ password: '', confirmPassword: '' });
      } else {
        await this.auth.signIn(email.trim().toLowerCase(), password);
        await this.router.navigateByUrl(this.route.snapshot.queryParamMap.get('returnUrl') ?? '/');
      }
    } catch (error) {
      this.errorMessage.set(this.friendlyError(error));
    } finally {
      this.submitting.set(false);
    }
  }

  async sendPasswordReset(): Promise<void> {
    const email = this.form.controls.email.value.trim().toLowerCase();
    if (this.form.controls.email.invalid || this.submitting()) {
      this.form.controls.email.markAsTouched();
      return;
    }

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.auth.sendPasswordReset(email);
      this.successMessage.set('Password reset email sent. Open the link in the email to continue.');
    } catch (error) {
      this.errorMessage.set(this.friendlyError(error));
    } finally {
      this.submitting.set(false);
    }
  }

  switchMode(): void {
    this.mode.update((mode) => (mode === 'signin' ? 'signup' : 'signin'));
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  showForgotPassword(): void {
    this.mode.set('forgot');
    this.errorMessage.set(null);
    this.successMessage.set(null);
  }

  private isCurrentModeValid(): boolean {
    if (this.mode() === 'forgot') return this.form.controls.email.valid;
    return this.form.valid;
  }

  private friendlyError(error: unknown): string {
    const authError = error as { code?: string; message?: string };
    if (authError.code === 'over_email_send_rate_limit') {
      return 'Too many signup attempts were made. Wait at least 60 seconds, then use Sign in if the account was already created.';
    }
    if (authError.code === 'email_not_confirmed') {
      return 'This account was created before confirmation was disabled. Recreate or confirm it once in Supabase Authentication → Users.';
    }
    return authError.message ?? 'Unable to continue.';
  }
}
