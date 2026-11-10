create table public.journal (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops,
 entry_date date not null,
 debit text not null check(debit in ('Cash','Other assets','Liabilities','Capital','Other income','Expenses')),
 credit text not null check(credit in ('Cash','Other assets','Liabilities','Capital','Other income','Expenses')),
 amount numeric(14,2) not null check(amount>0),
 description text not null check(length(trim(description))>0),
 created_by uuid not null default auth.uid() references auth.users,
 check(debit<>credit)
);
create index journal_shop_date_idx on public.journal(shop_id,entry_date);
alter table public.journal enable row level security;
create policy journal_read on public.journal for select to authenticated using(public.can_access(shop_id,'reports'));
create policy journal_post on public.journal for insert to authenticated with check(public.can_access(shop_id,'accounting') and created_by=(select auth.uid()));
create policy journal_accounting_read on public.journal for select to authenticated using(public.can_access(shop_id,'accounting'));
revoke execute on function public.is_owner(), public.can_access(uuid,text), public.record_release(uuid,date,integer,numeric), public.review_release(uuid) from public, anon;
grant execute on function public.is_owner(), public.can_access(uuid,text), public.record_release(uuid,date,integer,numeric), public.review_release(uuid) to authenticated;
