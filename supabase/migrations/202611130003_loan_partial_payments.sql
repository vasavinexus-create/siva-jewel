create table public.loan_partial_payments (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null,
 loan_id uuid not null,
 paid_on date not null check (isfinite(paid_on)),
 interest_advance numeric(14,2) not null check (interest_advance>=0 and interest_advance<'NaN'::numeric),
 principal_paid numeric(14,2) not null check (principal_paid>=0 and principal_paid<'NaN'::numeric),
 payment_ledger_id uuid,
 created_by uuid not null references auth.users,
 check (interest_advance+principal_paid>0),
 foreign key (shop_id,loan_id) references public.loans(shop_id,id),
 foreign key (shop_id,payment_ledger_id) references public.ledgers(shop_id,id)
);
create index loan_partial_payments_bill on public.loan_partial_payments(shop_id,loan_id,paid_on,id);
alter table public.loan_partial_payments enable row level security;
grant select on public.loan_partial_payments to authenticated;
create policy loan_partial_payments_read on public.loan_partial_payments for select to authenticated using (
 public.can_access(shop_id,'release') or public.can_access(shop_id,'accounting')
);

create function private.record_loan_partial_payment(s uuid,loan uuid,payment_date date,advance numeric,principal numeric,interest_only boolean,bank uuid)
returns uuid language plpgsql set search_path='' as $$
declare l public.loans; saved_id uuid; balance numeric;
begin
 select * into l from public.loans where (shop_id,id)=(s,loan) for update;
 if not found or exists(select 1 from public.releases where loan_id=loan) then
   raise exception 'Select an open bill';
 end if;
 if payment_date is null or not isfinite(payment_date) or payment_date<l.loan_date
   or payment_date>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Payment date must be between the pledge date and today';
 end if;
 if advance is null or principal is null or advance<0 or principal<0 or advance+principal<=0
   or advance+principal>=1000000000000 or advance<>round(advance,2) or principal<>round(principal,2) then
   raise exception 'Enter valid payment amounts with up to two decimal places';
 end if;
 if interest_only then
   advance := advance+principal;
   principal := 0;
 end if;
 if principal>0 and exists(select 1 from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(s,loan) and p.paid_on>payment_date and p.principal_paid>0) then
   raise exception 'Principal payments must be entered in date order';
 end if;
 select l.amount+coalesce((select sum(t.amount) from public.loan_top_ups t
   where (t.shop_id,t.loan_id)=(s,loan) and t.paid_on<=payment_date),0)
   -coalesce((select sum(p.principal_paid) from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(s,loan) and p.paid_on<=payment_date),0)
 into balance;
 if principal>balance then raise exception 'Principal payment exceeds the outstanding principal'; end if;
 insert into public.loan_partial_payments(shop_id,loan_id,paid_on,interest_advance,principal_paid,payment_ledger_id,created_by)
 values(s,loan,payment_date,advance,principal,bank,auth.uid()) returning id into saved_id;
 return saved_id;
end
$$;

create or replace function public.release_quote(loan uuid,on_date date,billed_months integer,monthly_rate numeric,full_principal boolean)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare
 l public.loans;
 m integer;
 charged integer;
 applied_rate numeric;
 principal numeric;
 breakdown jsonb;
 gross_interest numeric;
 interest_due numeric;
 advance numeric;
begin
 select * into l from public.loans where id=loan;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 if exists(select 1 from public.releases where loan_id=loan) then raise exception 'Loan has already been released'; end if;
 if on_date is null or not isfinite(on_date) or on_date<l.loan_date then
   raise exception 'Release date must be on or after the pledge date';
 end if;
 if exists(select 1 from public.loan_top_ups t where (t.shop_id,t.loan_id)=(l.shop_id,l.id) and t.paid_on>on_date) then
   raise exception 'Release date must be on or after the last top-up date';
 end if;
 if exists(select 1 from public.loan_partial_payments p where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and p.paid_on>on_date) then
   raise exception 'Date must be on or after the last partial payment';
 end if;
 select l.advance_interest+coalesce(sum(p.interest_advance),0) into advance
 from public.loan_partial_payments p where (p.shop_id,p.loan_id)=(l.shop_id,l.id);
 m := private.charged_loan_months(l.loan_date,on_date);
 charged := coalesce(billed_months,m);
 applied_rate := round(coalesce(monthly_rate,l.rate),4);
 if charged<0 or applied_rate<0 or applied_rate>=10000 then raise exception 'Invalid months or rate'; end if;
 with payments as (
   select l.id,l.loan_date as paid_on,l.amount,true as original,false as reduction
   union all
   select t.id,t.paid_on,t.amount,false,false from public.loan_top_ups t where (t.shop_id,t.loan_id)=(l.shop_id,l.id)
   union all
   select p.id,p.paid_on,-p.principal_paid,false,true from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and p.principal_paid>0
 ), amounts as (
   select * from payments where not full_principal or reduction
   union all
   select l.id,l.loan_date,sum(amount),true,false from payments
   where full_principal and not reduction having count(*)>0
 ), charges as (
   select *,case when full_principal and not reduction then charged
     when reduction then greatest(0,charged-greatest(1,billing_boundary))
     else greatest(0,charged-(billing_boundary -
       case when (l.loan_date+make_interval(months=>billing_boundary))::date>paid_on then 1 else 0 end))
     end as months
   from amounts
   cross join lateral (select private.charged_loan_months(l.loan_date,paid_on) as billing_boundary) period
 )
 select sum(amount),sum(round(amount*months*applied_rate/100,2)),
   jsonb_agg(jsonb_build_object('date',paid_on,'amount',amount,'months',months,
     'monthly_interest',round(amount*applied_rate/100,2),
     'interest',round(amount*months*applied_rate/100,2)) order by original desc,paid_on,id)
 into principal,gross_interest,breakdown from charges;
 interest_due := greatest(0,gross_interest-advance);
 return jsonb_build_object('bill',l.bill,'loan_date',l.loan_date,'grams',l.grams,'notes',l.notes,'photo',l.photo,
   'amount',principal,'months',charged,'rate',applied_rate,'gross_interest',gross_interest,
   'advance_interest',advance,'interest',interest_due,'total',principal+interest_due,
   'original_months',m,'breakdown',breakdown);
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
 permission := case operation when 'pledge' then 'loans' when 'top_up' then 'loans' when 'journal' then 'accounting'
   when 'partial_payment' then 'release' when 'release' then 'release' when 'review' then 'audit' end;
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
 if operation in ('pledge','top_up','release','partial_payment') then
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
 elsif operation='top_up' then
   target := private.record_loan_top_up(s,(payload->>'loan')::uuid,
     (payload->>'paid_on')::date,(payload->>'amount')::numeric,bank);
 elsif operation='partial_payment' then
   target := private.record_loan_partial_payment(s,(payload->>'loan')::uuid,(payload->>'paid_on')::date,
     (payload->>'interest_advance')::numeric,(payload->>'principal_paid')::numeric,
     coalesce((payload->>'interest_only')::boolean,false),bank);
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
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,(payload->>'monthly_rate')::numeric,coalesce((payload->>'full_principal')::boolean,false),payload->'expected_quote',(payload->>'received_amount')::numeric);
     if bank is not null then update public.releases set payment_ledger_id=bank where loan_id=target; end if;
   else
     update public.releases r set reviewed_at=now(),reviewed_by=request_actor
     where r.shop_id=s and r.loan_id=target and r.reviewed_at is null
       and (r.rate<>r.original_rate or r.months<>r.original_months or r.total<r.calculated_total);
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
 select r.shop_id,r.loan_id,2,r.release_date,'Release '||l.bill,case when r.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Pawn loans',r.total-r.interest,r.payment_ledger_id,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id) where r.total>r.interest
 union all
 select r.shop_id,r.loan_id,3,r.release_date,'Release '||l.bill,case when r.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Interest income',r.interest,r.payment_ledger_id,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id) where r.interest<>0
 union all
 select shop_id,id,4,entry_date,description,debit,credit,amount,debit_ledger_id,credit_ledger_id from public.journal
 union all
 select shop_id,id,5,loan_date,'Advance interest '||bill,'Pawn loans','Interest income',advance_interest,null::uuid,null::uuid
 from public.loans where advance_interest>0
 union all
 select t.shop_id,t.id,6,t.paid_on,'Top-up '||l.bill,'Pawn loans',
   case when t.payment_ledger_id is null then 'Cash' else 'Other assets' end,
   t.amount,null::uuid,t.payment_ledger_id
 from public.loan_top_ups t join public.loans l on (l.shop_id,l.id)=(t.shop_id,t.loan_id)
 union all
 select r.shop_id,r.loan_id,7,r.release_date,'Release write-off '||l.bill,'Expenses','Pawn loans',
   r.principal_write_off,null::uuid,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where r.principal_write_off>0
 union all
 select p.shop_id,p.id,8,p.paid_on,'Partial principal payment '||l.bill,
   case when p.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Pawn loans',
   p.principal_paid,p.payment_ledger_id,null::uuid
 from public.loan_partial_payments p join public.loans l on (l.shop_id,l.id)=(p.shop_id,p.loan_id)
 where p.principal_paid>0
 union all
 select p.shop_id,p.id,9,p.paid_on,'Partial interest payment '||l.bill,
   case when p.payment_ledger_id is null then 'Cash' else 'Other assets' end,'Interest income',
   p.interest_advance,p.payment_ledger_id,null::uuid
 from public.loan_partial_payments p join public.loans l on (l.shop_id,l.id)=(p.shop_id,p.loan_id)
 where p.interest_advance>0;

create or replace function public.report_summary(s uuid,kind text,from_date date,to_date date)
returns jsonb language plpgsql stable set search_path='' as $$
declare b jsonb; profit numeric; assets numeric;
begin
 if not public.can_access(s,'reports') then raise exception 'Report access denied'; end if;
 if kind='Loan balance' then
   return (select jsonb_build_object('principal',coalesce(sum(l.amount+coalesce((
      select sum(t.amount) from public.loan_top_ups t where t.shop_id=l.shop_id and t.loan_id=l.id
      and (to_date is null or t.paid_on<=to_date)
    ),0)-coalesce((
      select sum(p.principal_paid) from public.loan_partial_payments p
      where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and (to_date is null or p.paid_on<=to_date)
    ),0)),0))
    from public.loans l where l.shop_id=s and (to_date is null or l.loan_date<=to_date)
    and not exists(select 1 from public.releases r where r.loan_id=l.id and (to_date is null or r.release_date<=to_date)));
 end if;
 select jsonb_object_agg(a.account,coalesce(t.balance,0)) into b
 from unnest(array['Cash','Other assets','Liabilities','Capital','Other income','Expenses','Pawn loans','Interest income']) a(account)
 left join (
   select v.account,sum(v.amount) as balance from public.ledger_entries e
   cross join lateral (values(e.debit,e.amount),(e.credit,-e.amount)) v(account,amount)
   where e.shop_id=s and (to_date is null or e.entry_date<=to_date)
   and (kind<>'Profit and loss' or from_date is null or e.entry_date>=from_date)
   group by v.account
 ) t using(account);
 profit := -(b->>'Interest income')::numeric-(b->>'Other income')::numeric-(b->>'Expenses')::numeric;
 assets := (b->>'Cash')::numeric+(b->>'Pawn loans')::numeric+(b->>'Other assets')::numeric;
 case kind
 when 'Profit and loss' then
   return jsonb_build_array(jsonb_build_array('Interest income',-(b->>'Interest income')::numeric),
    jsonb_build_array('Other income',-(b->>'Other income')::numeric),jsonb_build_array('Expenses',b->'Expenses'),
    jsonb_build_array('Net profit',profit));
 when 'Balance sheet' then
   return jsonb_build_array(jsonb_build_array('Cash',b->'Cash'),jsonb_build_array('Pawn loans',b->'Pawn loans'),
    jsonb_build_array('Other assets',b->'Other assets'),jsonb_build_array('Total assets',assets),
    jsonb_build_array('Liabilities',-(b->>'Liabilities')::numeric),jsonb_build_array('Capital',-(b->>'Capital')::numeric),
    jsonb_build_array('Accumulated earnings',profit),
    jsonb_build_array('Total liabilities and equity',profit-(b->>'Liabilities')::numeric-(b->>'Capital')::numeric));
 when 'Trial balance' then
   return (select jsonb_agg(jsonb_build_array(account,greatest(balance::numeric,0),greatest(-balance::numeric,0)) order by account)
     from jsonb_each_text(b) a(account,balance));
 else raise exception 'Unknown summary';
 end case;
end
$$;
