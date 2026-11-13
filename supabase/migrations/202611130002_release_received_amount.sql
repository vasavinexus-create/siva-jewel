alter table public.releases
 add column calculated_total numeric(18,2),
 add column principal_write_off numeric(18,2) not null default 0;

create function public.record_release(loan uuid,on_date date,billed_months integer,monthly_rate numeric,
 full_principal boolean,expected_quote jsonb,received_amount numeric)
returns void language plpgsql security definer set search_path='' as $$
declare l public.loans; quote jsonb; received numeric; principal numeric;
begin
 select * into l from public.loans where id=loan for update;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 quote := public.release_quote(loan,on_date,billed_months,monthly_rate,full_principal);
 if expected_quote is not null and expected_quote is distinct from quote then
   raise exception 'The release quote changed. Refresh the quote before recording the release.';
 end if;
 received := coalesce(received_amount,(quote->>'total')::numeric);
 principal := (quote->>'amount')::numeric;
 if received<0 or received>=10000000000000000 or received<>round(received,2) then
   raise exception 'Enter a valid received amount with up to two decimal places';
 end if;
 insert into public.releases(loan_id,shop_id,release_date,months,rate,interest,total,original_months,
   original_rate,created_by,full_principal,interest_breakdown,calculated_total,principal_write_off)
 values(l.id,l.shop_id,on_date,(quote->>'months')::int,(quote->>'rate')::numeric,greatest(0,received-principal),
   received,(quote->>'original_months')::int,l.rate,auth.uid(),full_principal,quote->'breakdown',(quote->>'total')::numeric,greatest(0,principal-received));
end
$$;
revoke execute on function public.record_release(uuid,date,integer,numeric,boolean,jsonb,numeric) from public,anon,authenticated;


create or replace function public.record_release(loan uuid,on_date date,billed_months integer,monthly_rate numeric,
 full_principal boolean,expected_quote jsonb)
returns void language sql security definer set search_path='' as $$
 select public.record_release(loan,on_date,billed_months,monthly_rate,full_principal,expected_quote,null)
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
 if operation in ('pledge','top_up','release') then
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
 where r.principal_write_off>0;

create or replace view public.pending_releases with (security_invoker=true) as
 select r.shop_id,r.loan_id,l.bill,r.release_date,r.months,r.original_months,r.rate,r.original_rate,
   r.calculated_total,r.total as received_amount
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where public.can_access(r.shop_id,'audit') and r.reviewed_at is null
 and (r.rate<>r.original_rate or r.months<>r.original_months or r.total<r.calculated_total);

create or replace function public.review_release(loan uuid)
returns void language sql security definer set search_path='' as $$
 update public.releases r set reviewed_at=now(),reviewed_by=auth.uid()
 where r.loan_id=loan and r.reviewed_at is null and public.can_access(r.shop_id,'audit')
 and (r.rate<>r.original_rate or r.months<>r.original_months or r.total<r.calculated_total)
$$;
