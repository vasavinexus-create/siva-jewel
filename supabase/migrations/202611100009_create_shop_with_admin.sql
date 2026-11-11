create function public.create_shop_with_admin(shop_name text, admin_id uuid, admin_email text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  new_shop_id uuid;
begin
  if not public.is_owner() then
    raise exception 'Shop access denied' using errcode = '42501';
  end if;
  if nullif(trim(shop_name), '') is null then
    raise exception 'Shop name is required' using errcode = '22023';
  end if;

  insert into public.shops (name)
  values (trim(shop_name))
  returning id into new_shop_id;

  insert into public.staff (shop_id, user_id, email, pages)
  values (new_shop_id, admin_id, admin_email, array['admin']);

  return new_shop_id;
end;
$$;

revoke execute on function public.create_shop_with_admin(text, uuid, text) from public, anon;
grant execute on function public.create_shop_with_admin(text, uuid, text) to authenticated;
