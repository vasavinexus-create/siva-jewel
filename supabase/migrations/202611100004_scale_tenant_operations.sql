create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;

create index shops_name_id_idx on public.shops(name,id);
create index customers_shop_name_idx on public.customers(shop_id,name,id);
create index customers_shop_mobile_idx on public.customers(shop_id,(regexp_replace(mobile,'[^0-9]','','g')));
create index customers_search_idx on public.customers using gin
 ((lower(name||' '||mobile)) extensions.gin_trgm_ops);
create index loans_shop_bill_ci_idx on public.loans(shop_id,(lower(bill)));
create index loans_bill_search_idx on public.loans using gin ((lower(bill)) extensions.gin_trgm_ops);
create index loans_shop_customer_history_idx on public.loans(shop_id,customer_id,loan_date desc,id);
create index releases_shop_report_idx on public.releases(shop_id,release_date,loan_id);
create index journal_shop_browse_idx on public.journal(shop_id,entry_date desc,id);

create or replace function public.search_customers(s uuid, term text)
returns table(id uuid,name text,mobile text) language sql stable set search_path='' as $$
 with input as (
   select lower(trim(term)) as query, regexp_replace(term,'[^0-9]','','g') as digits,
     '%'||replace(replace(replace(lower(trim(term)),'!','!!'),'%','!%'),'_','!_')||'%' as pattern
 )
 select c.id,c.name,c.mobile from public.customers c cross join input i
 where c.shop_id=s and (i.query='' or lower(c.name||' '||c.mobile) like i.pattern escape '!'
   or (i.query ~ '^[+0-9() .-]+$' and i.digits<>'' and regexp_replace(c.mobile,'[^0-9]','','g')=i.digits))
 order by c.name,c.id limit 50
$$;

create or replace function public.search_open_loans(s uuid, term text)
returns table(id uuid,bill text,customer text,exact_bill boolean) language sql stable set search_path='' as $$
 with input as (
   select lower(trim(term)) as query, regexp_replace(term,'[^0-9]','','g') as digits,
     '%'||replace(replace(replace(lower(trim(term)),'!','!!'),'%','!%'),'_','!_')||'%' as pattern
 ), candidates as (
   select l.id from public.loans l cross join input i where l.shop_id=s and lower(l.bill)=i.query
   union
   select l.id from public.loans l cross join input i where l.shop_id=s and lower(l.bill) like i.pattern escape '!'
   union
   select l.id from public.customers c join public.loans l on (l.shop_id,l.customer_id)=(c.shop_id,c.id)
   cross join input i where c.shop_id=s and i.query<>'' and
     (lower(c.name||' '||c.mobile) like i.pattern escape '!'
       or (i.query ~ '^[+0-9() .-]+$' and i.digits<>'' and regexp_replace(c.mobile,'[^0-9]','','g')=i.digits))
 )
 select l.id,l.bill,c.name,lower(l.bill)=i.query
 from public.loans l join public.customers c on (c.shop_id,c.id)=(l.shop_id,l.customer_id)
 cross join input i
 where l.shop_id=s and public.can_access(s,'release')
 and (i.query='' or l.id in (select candidates.id from candidates))
 and not exists(select 1 from public.releases r where r.loan_id=l.id)
 order by 4 desc,l.loan_date desc,l.id limit 50
$$;

create or replace view public.pending_releases with (security_invoker=true) as
 select r.shop_id,r.loan_id,l.bill,r.release_date,r.months,r.original_months,r.rate,r.original_rate
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where public.can_access(r.shop_id,'audit') and r.reviewed_at is null
 and (r.rate<>r.original_rate or r.months<>r.original_months);

create schema if not exists private;
create table private.financial_requests (
 shop_id uuid not null references public.shops,
 actor uuid not null,
 request_id uuid not null,
 operation text not null,
 payload jsonb not null,
 record_id uuid,
 primary key(shop_id,actor,request_id)
);

create function public.submit_financial(s uuid, request_id uuid, operation text, payload jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 request_actor uuid := auth.uid();
 permission text;
 saved private.financial_requests;
 target uuid;
begin
 permission := case operation when 'pledge' then 'loans' when 'journal' then 'accounting'
   when 'release' then 'release' when 'review' then 'audit' end;
 if permission is null or not public.can_access(s,permission) then
   raise exception 'Financial operation access denied' using errcode='42501';
 end if;
 if request_id is null or jsonb_typeof(payload) is distinct from 'object' then
   raise exception 'A request ID and input object are required' using errcode='22023';
 end if;
 insert into private.financial_requests(shop_id,actor,request_id,operation,payload)
 values(s,request_actor,request_id,operation,payload) on conflict on constraint financial_requests_pkey do nothing;
 if not found then
   select f.* into strict saved from private.financial_requests f
   where (f.shop_id,f.actor,f.request_id)=(s,request_actor,submit_financial.request_id);
   if (saved.operation,saved.payload) is distinct from (operation,payload) then
     raise exception 'Request ID was already used for different input' using errcode='22023';
   end if;
   return saved.record_id;
 end if;
 if operation='pledge' then
   if nullif(trim(payload->>'bill'),'') is null then raise exception 'Bill number is required'; end if;
   if payload->>'photo' is not null and (split_part(payload->>'photo','/',1)<>s::text
     or split_part(payload->>'photo','/',2)<>'jewel') then raise exception 'Invalid jewel photo path'; end if;
   if not isfinite((payload->>'loan_date')::date) or (payload->>'amount')::numeric='NaN'::numeric
     or (payload->>'grams')::numeric='NaN'::numeric or (payload->>'rate')::numeric='NaN'::numeric
     then raise exception 'Invalid pledge date or amount'; end if;
   insert into public.loans(shop_id,customer_id,bill,loan_date,amount,grams,rate,notes,photo)
   values(s,(payload->>'customer_id')::uuid,trim(payload->>'bill'),(payload->>'loan_date')::date,
     (payload->>'amount')::numeric,(payload->>'grams')::numeric,(payload->>'rate')::numeric,
     payload->>'notes',payload->>'photo') returning id into target;
 elsif operation='journal' then
   if not isfinite((payload->>'entry_date')::date) or (payload->>'amount')::numeric='NaN'::numeric
     then raise exception 'Invalid journal date or amount'; end if;
   insert into public.journal(shop_id,entry_date,description,debit,credit,amount,created_by)
   values(s,(payload->>'entry_date')::date,trim(payload->>'description'),payload->>'debit',payload->>'credit',
     (payload->>'amount')::numeric,request_actor) returning id into target;
 else
   target := (payload->>'loan')::uuid;
   if not exists(select 1 from public.loans l where l.id=target and l.shop_id=s) then
     raise exception 'Loan unavailable';
   end if;
   if operation='release' then
     if payload->>'billed_months' is null or payload->>'monthly_rate' is null then raise exception 'Months and rate are required'; end if;
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,(payload->>'monthly_rate')::numeric);
   else
     update public.releases r set reviewed_at=now(),reviewed_by=request_actor
     where r.shop_id=s and r.loan_id=target and r.reviewed_at is null
       and (r.rate<>r.original_rate or r.months<>r.original_months);
     if not found then raise exception 'Release is no longer pending'; end if;
   end if;
 end if;
 update private.financial_requests f set record_id=target
 where (f.shop_id,f.actor,f.request_id)=(s,request_actor,submit_financial.request_id);
 return target;
end
$$;

revoke all on private.financial_requests from public,anon,authenticated;
revoke execute on function public.submit_financial(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.submit_financial(uuid,uuid,text,jsonb) to authenticated;
