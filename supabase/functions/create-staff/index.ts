import { loginEmail } from '../_shared/login.js';
import { createClient } from 'npm:@supabase/supabase-js@2';

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Content-Type': 'application/json',
};
const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status, headers });
const allowedPages = ['shop', 'customers', 'customer_edit', 'loans', 'release', 'release_edit', 'reports', 'accounting', 'journal', 'balances', 'audit', 'pledge_edit_all', 'pledge_edit_details'];

Deno.serve(async req => {
  if (req.method === 'OPTIONS') return new Response(null, { headers });
  if (req.method !== 'POST') return reply(405, { error: 'POST required' });
  try {
    const auth = req.headers.get('Authorization');
    if (!auth?.startsWith('Bearer ')) return reply(401, { error: 'Sign in required' });
    const url = Deno.env.get('SUPABASE_URL')!;
    const caller = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, {
      global: { headers: { Authorization: auth } },
      auth: { persistSession: false },
    });
    const { data: identity, error: identityError } = await caller.auth.getUser(auth.slice(7));
    if (identityError || !identity.user) return reply(401, { error: 'Sign in required' });
    const { shop, shopName, logo = null, username, password, administratorId, staffId, admin = false, pages = [] } = await req.json();
    if (administratorId !== undefined || staffId !== undefined) {
      const editingAdmin = administratorId !== undefined;
      const userId = editingAdmin ? administratorId : staffId;
      const email = username === undefined ? null : loginEmail(username);
      if (typeof shop !== 'string' || typeof userId !== 'string' ||
          (username !== undefined && !email) || (editingAdmin && staffId !== undefined) ||
          typeof password !== 'string' || (password !== '' && password.length < 6)) {
        return reply(400, { error: 'Invalid login details' });
      }
      const permitted = editingAdmin ? await caller.rpc('is_owner') :
        await caller.rpc('can_access', { s: shop, p: 'admin' });
      if (permitted.error || !permitted.data) return reply(403, { error: 'Shop access denied' });

      const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
      const [membership, platformOwner] = await Promise.all([
        service.from('staff').select('shop_id,pages').eq('user_id', userId),
        service.from('owners').select('user_id').eq('user_id', userId).maybeSingle(),
      ]);
      if (membership.error || platformOwner.error) return reply(500, { error: 'Could not verify the shop administrator' });
      const target = membership.data.find(row => row.shop_id === shop);
      if (!target || target.pages.includes('admin') !== editingAdmin || platformOwner.data ||
          (!editingAdmin && membership.data.length !== 1)) {
        return reply(403, { error: 'This account cannot be edited from this shop' });
      }
      const { data: current, error: lookupError } = await service.auth.admin.getUserById(userId);
      if (lookupError || !current.user) return reply(500, { error: 'Could not load the account login' });
      const newEmail = email && current.user.email?.toLowerCase() !== email ? email : null;
      if (!newEmail && !password) return reply(200, { id: userId });
      const { error } = await service.auth.admin.updateUserById(userId, {
        ...(newEmail ? { email: newEmail, email_confirm: true } : {}),
        ...(password ? { password } : {}),
      });
      if (error?.code === 'email_exists' || error?.code === 'user_already_exists') {
        return reply(409, { error: 'This username is already in use. Choose a unique username.' });
      }
      if (error) return reply(400, { error: error.message });
      return reply(200, { id: userId });
    }
    const creatingShop = shopName !== undefined;
    const name = typeof shopName === 'string' ? shopName.trim() : '';
    if (logo !== null && (!creatingShop || typeof logo !== 'string' || logo.length > 100000 ||
        !/^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/.test(logo))) {
      return reply(400, { error: 'Invalid shop logo' });
    }
    const email = loginEmail(username);
    if ((creatingShop ? !name || admin !== true || shop !== undefined : typeof shop !== 'string') ||
        !email || typeof password !== 'string' || password.length < 6 ||
        typeof admin !== 'boolean' || !Array.isArray(pages) || pages.some(p => !allowedPages.includes(p))) {
      return reply(400, { error: 'Invalid staff details' });
    }
    const permitted = admin ? await caller.rpc('is_owner') : await caller.rpc('can_access', { s: shop, p: 'admin' });
    if (permitted.error || !permitted.data) return reply(403, { error: 'Shop access denied' });

    const service = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data, error } = await service.auth.admin.createUser({ email, password, email_confirm: true });
    if (error?.code === 'email_exists' || error?.code === 'user_already_exists') {
      return reply(409, { error: 'This username is already in use. Choose a unique username.' });
    }
    if (error || !data.user) return reply(400, { error: error?.message || 'User creation failed' });
    const membership = creatingShop
      ? await caller.rpc('create_shop_with_admin', { shop_name: name, admin_id: data.user.id, admin_email: email, shop_logo: logo })
      : await caller.from('staff').insert({
      shop_id: shop, user_id: data.user.id, email: data.user.email,
      pages: admin ? ['admin'] : [...new Set(['shop', ...pages])],
    });
    if (membership.error) {
      const cleanup = await service.auth.admin.deleteUser(data.user.id);
      if (cleanup.error) console.error('Auth cleanup failed', data.user.id, cleanup.error.message);
      return reply(400, { error: creatingShop ? 'The shop and its administrator could not be saved' : 'Shop membership could not be saved' });
    }
    return reply(201, { id: data.user.id, shopId: creatingShop ? membership.data : shop });
  } catch (error) {
    console.error(error);
    return reply(400, { error: 'Unable to create staff account' });
  }
});
