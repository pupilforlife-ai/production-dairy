import { createClient } from 'npm:@supabase/supabase-js@2.112.3';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

type OwnerActionRequest = {
  action?: 'reset_password' | 'delete_user';
  userId?: string;
  password?: string;
};

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, { status, headers: corsHeaders });
}

function readDefaultSecret(): string | null {
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (serviceRoleKey) return serviceRoleKey;

  const secretMap = Deno.env.get('SUPABASE_SECRET_KEYS');
  if (secretMap) {
    try {
      const parsed = JSON.parse(secretMap) as Record<string, string>;
      if (parsed.default) return parsed.default;
    } catch {
      // Fall back to the legacy runtime variable below.
    }
  }
  return null;
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return jsonResponse({ error: 'Method not allowed.' }, 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const secretKey = readDefaultSecret();
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? secretKey;
  if (!supabaseUrl || !secretKey)
    return jsonResponse({ error: 'Server configuration error.' }, 500);

  const authorization = request.headers.get('Authorization');
  const accessToken = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!accessToken) return jsonResponse({ error: 'Authentication required.' }, 401);

  const admin = createClient(supabaseUrl, secretKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const userClient = createClient(supabaseUrl, anonKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
  const { data: authData, error: authError } = await admin.auth.getUser(accessToken);
  if (authError || !authData.user) return jsonResponse({ error: 'Your session is invalid.' }, 401);

  const callerId = authData.user.id;
  const { data: callerProfile, error: callerError } = await userClient
    .from('profiles')
    .select('role, active, approval_status')
    .eq('id', callerId)
    .single();
  const callerRole = callerProfile?.role;
  const callerCanAdministerWorkers = callerRole === 'owner' || callerRole === 'admin';
  if (
    callerError ||
    !callerCanAdministerWorkers ||
    callerProfile?.active !== true ||
    callerProfile?.approval_status !== 'approved'
  ) {
    return jsonResponse({ error: 'Owner or admin access required.' }, 403);
  }

  let body: OwnerActionRequest;
  try {
    body = (await request.json()) as OwnerActionRequest;
  } catch {
    return jsonResponse({ error: 'Invalid request.' }, 400);
  }

  if (
    !body.userId ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(body.userId)
  ) {
    return jsonResponse({ error: 'A valid user is required.' }, 400);
  }

  const { data: targetProfile, error: targetError } = await admin
    .from('profiles')
    .select('id, display_name, role, approval_status')
    .eq('id', body.userId)
    .single();
  if (targetError || !targetProfile) return jsonResponse({ error: 'User account not found.' }, 404);

  if (body.action === 'reset_password') {
    if (callerRole !== 'owner' && targetProfile.role !== 'factory_worker') {
      return jsonResponse({ error: 'Admins can only reset factory worker passwords.' }, 403);
    }

    if (
      typeof body.password !== 'string' ||
      body.password.length < 8 ||
      body.password.length > 72
    ) {
      return jsonResponse({ error: 'The new password must contain 8 to 72 characters.' }, 400);
    }

    const { error } = await admin.auth.admin.updateUserById(body.userId, {
      password: body.password,
    });
    if (error) return jsonResponse({ error: error.message }, 400);

    await admin.from('audit_events').insert({
      entity_type: 'user_account',
      entity_id: body.userId,
      action: callerRole === 'owner' ? 'password_reset_by_owner' : 'password_reset_by_admin',
      actor_user_id: callerId,
      new_data: { target_display_name: targetProfile.display_name },
    });
    return jsonResponse({ ok: true });
  }

  if (body.action === 'delete_user') {
    if (callerRole !== 'owner') {
      return jsonResponse({ error: 'Owner access required.' }, 403);
    }

    if (body.userId === callerId) {
      return jsonResponse({ error: 'You cannot delete your own owner account.' }, 400);
    }

    const { data: blockers, error: blockerError } = await admin.rpc('app_user_deletion_blockers', {
      requested_user_id: body.userId,
    });
    if (blockerError) return jsonResponse({ error: 'Unable to check the user history.' }, 500);
    if (Array.isArray(blockers) && blockers.length > 0) {
      return jsonResponse(
        {
          error:
            'This user has factory or audit history and cannot be permanently deleted. Set their status to Disapproved instead.',
        },
        409,
      );
    }

    const { error } = await admin.auth.admin.deleteUser(body.userId, false);
    if (error) {
      return jsonResponse(
        {
          error:
            'This user could not be deleted. If they have factory history, set their status to Disapproved instead.',
        },
        409,
      );
    }

    await admin.from('audit_events').insert({
      entity_type: 'user_account',
      entity_id: body.userId,
      action: 'deleted_by_owner',
      actor_user_id: callerId,
      old_data: {
        display_name: targetProfile.display_name,
        role: targetProfile.role,
        approval_status: targetProfile.approval_status,
      },
    });
    return jsonResponse({ ok: true });
  }

  return jsonResponse({ error: 'Unsupported owner action.' }, 400);
});
