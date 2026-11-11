create function public.sync_staff_login_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.staff set email = new.email where user_id = new.id;
  return new;
end;
$$;

revoke execute on function public.sync_staff_login_email() from public, anon, authenticated;

create trigger sync_staff_login_email
after update of email on auth.users
for each row when (old.email is distinct from new.email)
execute function public.sync_staff_login_email();
