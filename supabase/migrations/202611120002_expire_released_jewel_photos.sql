create index loans_jewel_photo_path_idx on public.loans(photo) where photo is not null;

create function private.jewel_photo_expired(path text, cutoff date)
returns boolean language sql stable set search_path='' as $$
 select exists(select 1 from public.loans l where l.photo=path
   and split_part(path,'/',1)=l.shop_id::text and split_part(path,'/',2)='jewel')
 and not exists(
   select 1 from public.loans l left join public.releases r on (r.shop_id,r.loan_id)=(l.shop_id,l.id)
   where l.photo=path and (r.loan_id is null or (r.release_date+interval '1 month')::date>cutoff)
 )
$$;

create function public.expired_jewel_photos(token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare cutoff date := (now() at time zone 'Asia/Kolkata')::date;
begin
 if not exists(select 1 from vault.decrypted_secrets v where v.name='siva_jewel_photo_cleanup' and v.decrypted_secret=token)
 then return null; end if;
 return coalesce((
   select jsonb_agg(path) from (
     select distinct l.photo as path from public.releases r join public.loans l
       on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
     where r.release_date<cutoff and (r.release_date+interval '1 month')::date<=cutoff
       and l.photo is not null and private.jewel_photo_expired(l.photo,cutoff)
     order by l.photo limit 100
   ) due
 ),'[]'::jsonb);
end
$$;

create function public.clear_expired_jewel_photos(paths text[])
returns void language sql security definer set search_path='' as $$
 update public.loans l set photo=null where l.photo=any(paths)
   and private.jewel_photo_expired(l.photo,(now() at time zone 'Asia/Kolkata')::date)
$$;

revoke execute on function private.jewel_photo_expired(text,date),
 public.expired_jewel_photos(text),public.clear_expired_jewel_photos(text[]) from public,anon,authenticated;
grant execute on function public.expired_jewel_photos(text),public.clear_expired_jewel_photos(text[]) to service_role;

-- Scheduled cleanup configuration.
create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$
begin
 if not exists(select 1 from vault.secrets where name='siva_jewel_photo_cleanup') then
   perform vault.create_secret(gen_random_uuid()::text||gen_random_uuid()::text,'siva_jewel_photo_cleanup');
 end if;
end
$$;

-- Run hourly at minute 17. The expiry calculation uses the shop calendar date.
select cron.schedule('siva-jewel-expire-photos','17 * * * *',$job$
 select net.http_post(
   url:='https://pwuukmjlojxcfbgryolm.supabase.co/functions/v1/expire-jewel-photos',
   headers:=jsonb_build_object('Content-Type','application/json','x-cleanup-token',
     (select decrypted_secret from vault.decrypted_secrets where name='siva_jewel_photo_cleanup')),
   timeout_milliseconds:=30000
 )
$job$);
