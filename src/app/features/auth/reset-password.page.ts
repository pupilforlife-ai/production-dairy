import { Component, inject, OnInit, signal } from '@angular/core';
import { FormControl, FormGroup, ReactiveFormsModule, Validators } from '@angular/forms';
import { ActivatedRoute, Router } from '@angular/router';
import { AuthService } from '../../core/auth/auth.service';

@Component({
  selector: 'app-reset-password-page',
  imports: [ReactiveFormsModule],
  templateUrl: './reset-password.page.html',
})
export class ResetPasswordPage implements OnInit {
  private readonly auth = inject(AuthService);
  private readonly route = inject(ActivatedRoute);
  private readonly router = inject(Router);
  readonly submitting = signal(false);
  readonly initializing = signal(true);
  readonly errorMessage = signal<string | null>(null);
  readonly successMessage = signal<string | null>(null);
  readonly form = new FormGroup({
    password: new FormControl('', {
      nonNullable: true,
      validators: [Validators.required, Validators.minLength(8)],
    }),
    confirmPassword: new FormControl('', { nonNullable: true }),
  });

  async ngOnInit(): Promise<void> {
    try {
      await this.auth.restorePasswordRecoverySession(this.route.snapshot.queryParamMap.get('code'));
    } catch (error) {
      this.errorMessage.set(this.friendlyError(error));
    } finally {
      this.initializing.set(false);
    }
  }

  async submit(): Promise<void> {
    if (this.form.invalid || this.submitting()) {
      this.form.markAllAsTouched();
      return;
    }

    const { password, confirmPassword } = this.form.getRawValue();
    if (password !== confirmPassword) {
      this.errorMessage.set('Passwords do not match.');
      return;
    }

    this.submitting.set(true);
    this.errorMessage.set(null);
    this.successMessage.set(null);
    try {
      await this.auth.updatePassword(password);
      this.successMessage.set('Password updated. You can sign in with the new password now.');
      await this.auth.signOut();
      this.form.reset();
    } catch (error) {
      this.errorMessage.set(this.friendlyError(error));
    } finally {
      this.submitting.set(false);
    }
  }

  async returnToSignIn(): Promise<void> {
    await this.router.navigate(['/login']);
  }

  private friendlyError(error: unknown): string {
    const authError = error as { message?: string };
    return authError.message ?? 'Unable to update your password.';
  }
}
