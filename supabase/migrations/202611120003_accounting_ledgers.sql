create table public.ledger_groups (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null references public.shops(id),
 name text not null check (length(trim(name)) between 1 and 100),
 category text not null check (category in ('Bank','Other assets','Liabilities','Capital','Other income','Expenses')),
 unique(shop_id,id)
);
create unique index ledger_groups_shop_name_idx on public.ledger_groups(shop_id,lower(trim(name)));

create table public.ledgers (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null,
 group_id uuid not null,
 name text not null check (length(trim(name)) between 1 and 100 and lower(trim(name))<>'cash'),
 unique(shop_id,id),
 foreign key(shop_id,group_id) references public.ledger_groups(shop_id,id)
);
create unique index ledgers_shop_name_idx on public.ledgers(shop_id,lower(trim(name)));
create index ledgers_shop_group_idx on public.ledgers(shop_id,group_id);

insert into public.ledger_groups(shop_id,name,category) select id,'Bank','Bank' from public.shops;
create function private.add_default_bank_group()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.ledger_groups(shop_id,name,category) values(new.id,'Bank','Bank');
 return new;
end
$$;
create trigger shops_default_bank_group after insert on public.shops
 for each row execute function private.add_default_bank_group();

alter table public.ledger_groups enable row level security;
alter table public.ledgers enable row level security;
create policy ledger_groups_read on public.ledger_groups for select to authenticated using (
 public.can_access(shop_id,'accounting') or public.can_access(shop_id,'reports')
 or (category='Bank' and (public.can_access(shop_id,'loans') or public.can_access(shop_id,'release')))
);
create policy ledgers_read on public.ledgers for select to authenticated using (
 public.can_access(shop_id,'accounting') or public.can_access(shop_id,'reports')
 or exists(select 1 from public.ledger_groups g where (g.shop_id,g.id)=(ledgers.shop_id,ledgers.group_id) and g.category='Bank')
);
create policy ledger_groups_create on public.ledger_groups for insert to authenticated with check (public.can_access(shop_id,'accounting'));
create policy ledgers_create on public.ledgers for insert to authenticated with check (public.can_access(shop_id,'accounting'));

alter table public.loans add column payment_ledger_id uuid,
 add foreign key(shop_id,payment_ledger_id) references public.ledgers(shop_id,id);
alter table public.releases add column payment_ledger_id uuid,
 add foreign key(shop_id,payment_ledger_id) references public.ledgers(shop_id,id);
alter table public.journal add column debit_ledger_id uuid,
 add column credit_ledger_id uuid,
 add foreign key(shop_id,debit_ledger_id) references public.ledgers(shop_id,id),
 add foreign key(shop_id,credit_ledger_id) references public.ledgers(shop_id,id),
 drop constraint journal_check,
 add constraint journal_distinct_accounts check (
  coalesce(debit_ledger_id::text,debit)<>coalesce(credit_ledger_id::text,credit)
 );

create function private.payment_bank_ledger(s uuid,mode text,ledger uuid)
returns uuid language plpgsql stable set search_path='' as $$
begin
 if mode='cash' and ledger is null then return null; end if;
 if mode='bank' and exists(
   select 1 from public.ledgers l join public.ledger_groups g on (g.shop_id,g.id)=(l.shop_id,l.group_id)
   where l.shop_id=s and l.id=ledger and g.category='Bank'
 ) then return ledger; end if;
 raise exception 'Select Cash or a bank ledger for this shop' using errcode='22023';
end
$$;

create function private.journal_category(s uuid,ledger uuid,account text)
returns text language plpgsql stable set search_path='' as $$
declare category_name text;
begin
 if ledger is null then return account; end if;
 select case when g.category='Bank' then 'Other assets' else g.category end into category_name
 from public.ledgers l join public.ledger_groups g on (g.shop_id,g.id)=(l.shop_id,l.group_id)
 where l.shop_id=s and l.id=ledger;
 if not found then raise exception 'Select a ledger from this shop' using errcode='22023'; end if;
 return category_name;
end
$$;

create or replace function public.submit_financial(s uuid, request_id uuid, operation text, payload jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 request_actor uuid := auth.uid();
 permission text;
 saved private.financial_requests;
 target uuid;
 advance numeric := 0;
 bank uuid;
 debit_id uuid;
 credit_id uuid;
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
 if operation in ('pledge','release') then
   bank := private.payment_bank_ledger(s,coalesce(payload->>'payment_mode','cash'),nullif(payload->>'payment_ledger_id','')::uuid);
 end if;
 if operation='pledge' then
   if nullif(trim(payload->>'bill'),'') is null then raise exception 'Bill number is required'; end if;
   if payload->>'photo' is not null and (split_part(payload->>'photo','/',1)<>s::text
     or split_part(payload->>'photo','/',2)<>'jewel') then raise exception 'Invalid jewel photo path'; end if;
   if not isfinite((payload->>'loan_date')::date) or (payload->>'amount')::numeric='NaN'::numeric
     or (payload->>'grams')::numeric='NaN'::numeric or (payload->>'rate')::numeric='NaN'::numeric
     then raise exception 'Invalid pledge date or amount'; end if;
   if payload->>'collect_advance'='true' then
     advance := (public.pledge_quote(s,(payload->>'amount')::numeric,(payload->>'rate')::numeric)->>'advance_interest')::numeric;
   end if;
   insert into public.loans(shop_id,customer_id,bill,loan_date,amount,grams,rate,notes,photo,advance_interest,payment_ledger_id)
   values(s,(payload->>'customer_id')::uuid,trim(payload->>'bill'),(payload->>'loan_date')::date,
     (payload->>'amount')::numeric,(payload->>'grams')::numeric,(payload->>'rate')::numeric,
     payload->>'notes',payload->>'photo',advance,bank) returning id into target;
 elsif operation='journal' then
   if not isfinite((payload->>'entry_date')::date) or (payload->>'amount')::numeric='NaN'::numeric
     then raise exception 'Invalid journal date or amount'; end if;
   debit_id := nullif(payload->>'debit_ledger_id','')::uuid;
   credit_id := nullif(payload->>'credit_ledger_id','')::uuid;
   insert into public.journal(shop_id,entry_date,description,debit,credit,amount,created_by,debit_ledger_id,credit_ledger_id)
   values(s,(payload->>'entry_date')::date,trim(payload->>'description'),
     private.journal_category(s,debit_id,payload->>'debit'),private.journal_category(s,credit_id,payload->>'credit'),
     (payload->>'amount')::numeric,request_actor,debit_id,credit_id) returning id into target;
 else
   target := (payload->>'loan')::uuid;
   if not exists(select 1 from public.loans l where l.id=target and l.shop_id=s) then
     raise exception 'Loan unavailable';
   end if;
   if operation='release' then
     if payload->>'billed_months' is null or payload->>'monthly_rate' is null then raise exception 'Months and rate are required'; end if;
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,(payload->>'monthly_rate')::numeric);
     if bank is not null then update public.releases set payment_ledger_id=bank where loan_id=target; end if;
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

create or replace view public.ledger_entries with (security_invoker=true) as
 select shop_id,id,1 as line,loan_date as entry_date,'Pledge '||bill as description,
   'Pawn loans'::text as debit,case when payment_ledger_id is null then 'Cash' else 'Other assets' end as credit,amount-advance_interest as amount,null::uuid as debit_ledger_id,payment_ledger_id as credit_ledger_id from public.loans
 union all
 select r.shop_id,r.loan_id,2,r.release_date,'Release '||l.bill,case when r.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Pawn loans',l.amount,r.payment_ledger_id,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 union all
 select r.shop_id,r.loan_id,3,r.release_date,'Release '||l.bill,case when r.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Interest income',r.interest,r.payment_ledger_id,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id) where r.interest<>0
 union all
 select shop_id,id,4,entry_date,description,debit,credit,amount,debit_ledger_id,credit_ledger_id from public.journal
 union all
 select shop_id,id,5,loan_date,'Advance interest '||bill,'Pawn loans','Interest income',advance_interest,null::uuid,null::uuid
 from public.loans where advance_interest>0;

create or replace function public.run_report(s uuid,kind text,from_date date,to_date date,page_cursor jsonb default null)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 headers text[];
 report_rows jsonb;
 summary text;
 next_cursor jsonb;
 cursor_date date := (page_cursor->>'date')::date;
 cursor_id uuid := (page_cursor->>'id')::uuid;
 cursor_line integer := (page_cursor->>'line')::integer;
 lower_date date := coalesce(from_date,'-infinity'::date);
 upper_date date := coalesce(to_date,'infinity'::date);
begin
 if not public.can_access(s,'reports') then raise exception 'Report access denied' using errcode='42501'; end if;
 if from_date>to_date then raise exception 'The start date must be on or before the end date.' using errcode='22023'; end if;
 if page_cursor is not null and (cursor_date is null or cursor_id is null or cursor_line is null) then
   raise exception 'Invalid report cursor' using errcode='22023';
 end if;
 case kind
 when 'Trial balance' then headers := array['Account','Debit balance','Credit balance'];
 when 'Profit and loss','Balance sheet' then headers := array['Account','Amount'];
 when 'Loan balance' then headers := array['Bill','Date','Principal'];
 when 'Pledging' then headers := array['Date','Bill','Principal','Advance interest','Paid out','Payment ledger'];
 when 'Releases' then headers := array['Date','Bill','Received','Interest','Payment ledger'];
 when 'Day book','General ledger' then headers := array['Date','Entry','Debit','Credit','Amount'];
 else raise exception 'Unknown report' using errcode='22023';
 end case;

 if kind in ('Trial balance','Profit and loss','Balance sheet') then
   select jsonb_agg(
     case when kind='Trial balance' then jsonb_build_array(item->>0,private.report_inr((item->>1)::numeric),private.report_inr((item->>2)::numeric))
     else jsonb_build_array(item->>0,private.report_inr((item->>1)::numeric)) end order by ordinal)
   into report_rows
   from jsonb_array_elements(public.report_summary(s,kind,from_date,to_date)) with ordinality as r(item,ordinal);
 else
   if kind='Loan balance' and page_cursor is null then
     summary := 'Outstanding principal '||private.report_inr((public.report_summary(s,kind,null,to_date)->>'principal')::numeric);
   end if;
   with candidates as (
     select l.loan_date as entry_date,l.id,0 as line,jsonb_build_array(l.loan_date,l.bill,private.report_inr(l.amount),private.report_inr(l.advance_interest),private.report_inr(l.amount-l.advance_interest),coalesce(account.name,'Cash')) as cells
     from public.loans l left join public.ledgers account on (account.shop_id,account.id)=(l.shop_id,l.payment_ledger_id)
     where kind='Pledging' and l.shop_id=s and l.loan_date between lower_date and upper_date
       and (cursor_date is null or (l.loan_date,l.id)>(cursor_date,cursor_id))
     union all
     select r.release_date,r.loan_id,0,jsonb_build_array(r.release_date,l.bill,private.report_inr(r.total),private.report_inr(r.interest),coalesce(account.name,'Cash'))
     from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
     left join public.ledgers account on (account.shop_id,account.id)=(r.shop_id,r.payment_ledger_id)
     where kind='Releases' and r.shop_id=s and r.release_date between lower_date and upper_date
       and (cursor_date is null or (r.release_date,r.loan_id)>(cursor_date,cursor_id))
     union all
     select l.loan_date,l.id,0,jsonb_build_array(l.bill,l.loan_date,private.report_inr(l.amount))
     from public.loans l
     where kind='Loan balance' and l.shop_id=s and l.loan_date<=upper_date
       and (cursor_date is null or (l.loan_date,l.id)>(cursor_date,cursor_id))
       and not exists(select 1 from public.releases r where r.loan_id=l.id and r.release_date<=upper_date)
     union all
     select e.entry_date,e.id,e.line,jsonb_build_array(e.entry_date,e.description,coalesce(d.name,e.debit),coalesce(c.name,e.credit),private.report_inr(e.amount))
     from public.ledger_entries e
     left join public.ledgers d on (d.shop_id,d.id)=(e.shop_id,e.debit_ledger_id)
     left join public.ledgers c on (c.shop_id,c.id)=(e.shop_id,e.credit_ledger_id)
     where kind in ('Day book','General ledger') and e.shop_id=s and e.entry_date between lower_date and upper_date
       and (cursor_date is null or (e.entry_date,e.id,e.line)>(cursor_date,cursor_id,cursor_line))
   ), page as (
     select * from candidates order by entry_date,id,line limit 51
   ), numbered as (
     select *,row_number() over(order by entry_date,id,line) as position from page
   )
   select jsonb_agg(cells order by position) filter(where position<=50),
     case when count(*)>50 then
       (jsonb_agg(jsonb_build_object('date',entry_date,'id',id,'line',line)) filter(where position=50))->0 end
   into report_rows,next_cursor from numbered;
 end if;
 return jsonb_build_object('title',kind,'headers',headers,'rows',coalesce(report_rows,'[]'::jsonb),
   'summary',summary,'next_cursor',next_cursor);
end
$$;

create function public.ledger_balances(s uuid)
returns table(name text,group_name text,balance numeric)
language plpgsql stable security definer set search_path='' as $$
begin
 if not public.can_access(s,'accounting') then raise exception 'Accounting access denied' using errcode='42501'; end if;
 return query
 with totals as (
   select side.ledger,side.account,sum(side.amount) as amount
   from public.ledger_entries e
   cross join lateral (values(e.debit_ledger_id,e.debit,e.amount),(e.credit_ledger_id,e.credit,-e.amount)) side(ledger,account,amount)
   where e.shop_id=s and e.entry_date<=(now() at time zone 'Asia/Kolkata')::date
   group by side.ledger,side.account
 )
 select 'Cash'::text,'Cash'::text,coalesce((select t.amount from totals t where t.ledger is null and t.account='Cash'),0)
 union all
 select l.name,g.name,coalesce(t.amount,0)
 from public.ledgers l join public.ledger_groups g on (g.shop_id,g.id)=(l.shop_id,l.group_id)
 left join totals t on t.ledger=l.id where l.shop_id=s;
end
$$;

revoke execute on function public.ledger_balances(uuid) from public,anon;
grant execute on function public.ledger_balances(uuid) to authenticated;

-- Older clients may still make direct Cash postings. Bank and custom ledger
-- postings go through submit_financial so the server can validate the account.
alter policy loans_add on public.loans with check (
 public.can_access(shop_id,'loans') and payment_ledger_id is null
);
alter policy journal_post on public.journal with check (
 public.can_access(shop_id,'accounting') and created_by=(select auth.uid())
 and debit_ledger_id is null and credit_ledger_id is null
);
