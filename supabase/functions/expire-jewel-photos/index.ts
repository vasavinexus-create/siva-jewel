import { createClient } from 'npm:@supabase/supabase-js@2';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response(null, { status: 405 });
  const token = request.headers.get('x-cleanup-token');
  if (!token) return new Response(null, { status: 401 });

  let removed = 0;
  for (let batch = 0; batch < 5; batch++) {
    const { data: paths, error: lookupError } = await db.rpc('expired_jewel_photos', { token });
    if (lookupError) {
      console.error('Jewel photo lookup failed', lookupError.code);
      return new Response(null, { status: 500 });
    }
    if (!paths) return new Response(null, { status: 401 });
    if (!paths.length) break;

    const { error: deleteError } = await db.storage.from('pawn-media').remove(paths);
    if (deleteError) {
      console.error('Jewel photo removal failed', deleteError.statusCode);
      return new Response(null, { status: 500 });
    }
    const { error: clearError } = await db.rpc('clear_expired_jewel_photos', { paths });
    if (clearError) {
      console.error('Jewel photo reference cleanup failed', clearError.code);
      return new Response(null, { status: 500 });
    }
    removed += paths.length;
  }
  return Response.json({ removed });
});
