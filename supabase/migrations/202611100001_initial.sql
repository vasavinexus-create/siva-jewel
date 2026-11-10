create table public.shops(id uuid primary key default gen_random_uuid(), name text not null, paused boolean not null default false);
create table public.owners(user_id uuid primary key references auth.users);
create table public.staff(shop_id uuid references public.shops, user_id uuid references auth.users, email text, pages text[] not null, primary key(shop_id,user_id));
create index staff_user_idx on public.staff(user_id);
create function public.is_owner() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.owners where user_id=(select auth.uid()))
$$;
create function public.can_access(s uuid,p text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.staff m join public.shops t on t.id=m.shop_id
 where m.shop_id=s and m.user_id=(select auth.uid()) and not t.paused and (p='shop' or p=any(m.pages) or 'admin'=any(m.pages)))
$$;
alter table public.owners enable row level security;
alter table public.shops enable row level security;
alter table public.staff enable row level security;
create policy owner_shops on public.shops for all to authenticated using ((select public.is_owner())) with check ((select public.is_owner()));
create policy staff_shops on public.shops for select to authenticated using (public.can_access(id,'shop'));
create policy staff_read on public.staff for select to authenticated using (user_id=(select auth.uid()) or public.can_access(shop_id,'admin') or (select public.is_owner()));
-- Only admins can configure ordinary staff. Admin membership is provisioned by the platform owner.
create policy staff_manage on public.staff for all to authenticated
using ((select public.is_owner()) or (public.can_access(shop_id,'admin') and not ('admin'=any(pages))))
with check ((select public.is_owner()) or (public.can_access(shop_id,'admin') and not ('admin'=any(pages))));
create table public.customers(
 id uuid primary key default gen_random_uuid(), shop_id uuid not null references public.shops,
 name text not null, village text, address text, mobile text not null, reference text, photo text, aadhaar_photo text,
 unique(shop_id,id)
);
create table public.loans(
 id uuid primary key default gen_random_uuid(), shop_id uuid not null, customer_id uuid not null,
 bill text not null, loan_date date not null, amount numeric(14,2) not null check(amount>0),
 grams numeric(12,3) not null check(grams>0), rate numeric(8,4) not null check(rate>=0), notes text, photo text,
 unique(shop_id,bill), unique(shop_id,id), foreign key(shop_id,customer_id) references public.customers(shop_id,id)
);
create index loans_customer_idx on public.loans(shop_id,customer_id);
create table public.releases(
 loan_id uuid primary key, shop_id uuid not null, release_date date not null,
 months integer not null check(months>=0), rate numeric(8,4) not null check(rate>=0),
 interest numeric(18,2) not null, total numeric(18,2) not null,
 original_months integer not null, original_rate numeric(8,4) not null,
 created_by uuid not null references auth.users, reviewed_at timestamptz, reviewed_by uuid references auth.users,
 foreign key(shop_id,loan_id) references public.loans(shop_id,id)
);
create index releases_shop_date_idx on public.releases(shop_id,release_date);
alter table public.customers enable row level security;
alter table public.loans enable row level security;
alter table public.releases enable row level security;
create policy customers_read on public.customers for select to authenticated using
 (public.can_access(shop_id,'customers') or public.can_access(shop_id,'loans') or public.can_access(shop_id,'release') or public.can_access(shop_id,'reports'));
create policy customers_add on public.customers for insert to authenticated with check(public.can_access(shop_id,'customers'));
create policy loans_read on public.loans for select to authenticated using
 (public.can_access(shop_id,'loans') or public.can_access(shop_id,'release') or public.can_access(shop_id,'reports') or public.can_access(shop_id,'customers') or public.can_access(shop_id,'audit'));
create policy loans_add on public.loans for insert to authenticated with check(public.can_access(shop_id,'loans'));
create policy releases_read on public.releases for select to authenticated using
 (public.can_access(shop_id,'release') or public.can_access(shop_id,'reports') or public.can_access(shop_id,'audit') or public.can_access(shop_id,'customers'));
create function public.record_release(loan uuid, on_date date, billed_months integer, monthly_rate numeric)
returns void language plpgsql security definer set search_path='' as $$
declare l public.loans; m integer; i numeric; boundary date;
begin
 select * into l from public.loans where id=loan;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 if on_date<l.loan_date then raise exception 'Release date precedes loan date'; end if;
 m := (extract(year from on_date)::int-extract(year from l.loan_date)::int)*12
    + extract(month from on_date)::int-extract(month from l.loan_date)::int;
 boundary := (l.loan_date+make_interval(months=>m))::date;
 if boundary>on_date then m:=m-1; end if;
 if (l.loan_date+make_interval(months=>m))::date<on_date then m:=m+1; end if;
 monthly_rate := round(monthly_rate,4);
 i := round(l.amount*billed_months*monthly_rate/100,2);
 insert into public.releases values(l.id,l.shop_id,on_date,billed_months,monthly_rate,i,l.amount+i,m,l.rate,auth.uid(),null,null);
end
$$;
create function public.review_release(loan uuid) returns void language sql security definer set search_path='' as $$
 update public.releases set reviewed_at=now(),reviewed_by=auth.uid()
 where loan_id=loan and reviewed_at is null and public.can_access(shop_id,'audit')
 and (months<>original_months or rate<>original_rate)
$$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('pawn-media','pawn-media',false,10485760,array['image/jpeg','image/png','image/webp']);
create policy media_write on storage.objects for insert to authenticated with check (
 bucket_id='pawn-media' and
 ((split_part(name,'/',2)='jewel' and public.can_access(split_part(name,'/',1)::uuid,'loans'))
 or (split_part(name,'/',2) in ('customer','identity') and public.can_access(split_part(name,'/',1)::uuid,'customers'))));
create policy media_read on storage.objects for select to authenticated using (
 bucket_id='pawn-media' and
 ((split_part(name,'/',2)='jewel' and (public.can_access(split_part(name,'/',1)::uuid,'loans') or public.can_access(split_part(name,'/',1)::uuid,'release')))
 or (split_part(name,'/',2) in ('customer','identity') and public.can_access(split_part(name,'/',1)::uuid,'customers'))));
