alter table public.shops add column logo text
  check (length(logo) <= 100000 and logo ~ '^data:image/png;base64,[A-Za-z0-9+/]+={0,2}$');

create function public.create_shop_with_admin(shop_name text, admin_id uuid, admin_email text, shop_logo text)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  new_shop_id uuid;
begin
  new_shop_id := public.create_shop_with_admin(shop_name, admin_id, admin_email);
  if shop_logo is not null then
    update public.shops set logo = shop_logo where id = new_shop_id;
  end if;
  return new_shop_id;
end;
$$;

revoke execute on function public.create_shop_with_admin(text, uuid, text, text) from public, anon;
grant execute on function public.create_shop_with_admin(text, uuid, text, text) to authenticated;
