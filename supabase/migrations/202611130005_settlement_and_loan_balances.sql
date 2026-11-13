alter table public.releases add column advance_to_principal numeric(18,2) not null default 0;

create or replace function public.release_quote(loan uuid,on_date date,billed_months integer,monthly_rate numeric,full_principal boolean,partial_interest_only boolean)
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
 principal_credit numeric;
begin
 select * into l from public.loans where id=loan;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 if exists(select 1 from public.releases where loan_id=loan) then raise exception 'Loan has already been released'; end if;
 if on_date is null or not isfinite(on_date) or on_date<l.loan_date or on_date>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Release date must be between the pledge date and today';
 end if;
 if exists(select 1 from public.loan_top_ups t where (t.shop_id,t.loan_id)=(l.shop_id,l.id) and t.paid_on>on_date) then
   raise exception 'Release date must be on or after the last top-up date';
 end if;
 if exists(select 1 from public.loan_partial_payments p where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and p.paid_on>on_date) then
   raise exception 'Date must be on or after the last partial payment';
 end if;
 select l.advance_interest+coalesce(sum(p.interest_advance+case when partial_interest_only then p.principal_paid else 0 end),0) into advance
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
   where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and p.principal_paid>0 and not partial_interest_only
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
 principal_credit := least(principal,greatest(0,advance-gross_interest));
 return jsonb_build_object('bill',l.bill,'loan_date',l.loan_date,'grams',l.grams,'notes',l.notes,'photo',l.photo,
   'amount',principal-principal_credit,'advance_to_principal',principal_credit,
   'excess_advance',greatest(0,advance-gross_interest-principal_credit),'months',charged,'rate',applied_rate,'gross_interest',gross_interest,
   'advance_interest',advance,'interest',interest_due,'total',principal-principal_credit+interest_due,
   'partial_interest_only',partial_interest_only,'original_months',m,'breakdown',breakdown);
end
$$;

create or replace function public.release_quote(loan uuid,on_date date,billed_months integer,monthly_rate numeric,full_principal boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select public.release_quote(loan,on_date,billed_months,monthly_rate,full_principal,false)-'partial_interest_only'
$$;

create or replace function public.record_release(loan uuid,on_date date,billed_months integer,monthly_rate numeric,
 full_principal boolean,expected_quote jsonb,received_amount numeric,partial_interest_only boolean)
returns void language plpgsql security definer set search_path='' as $$
declare l public.loans; quote jsonb; received numeric; principal numeric;
begin
 select * into l from public.loans where id=loan for update;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 quote := public.release_quote(loan,on_date,billed_months,monthly_rate,full_principal,partial_interest_only);
 if expected_quote is not null and expected_quote is distinct from quote then
   raise exception 'The release quote changed. Refresh the quote before recording the release.';
 end if;
 received := coalesce(received_amount,(quote->>'total')::numeric);
 principal := (quote->>'amount')::numeric;
 if received<0 or received>=10000000000000000 or received<>round(received,2) then
   raise exception 'Enter a valid received amount with up to two decimal places';
 end if;
 insert into public.releases(loan_id,shop_id,release_date,months,rate,interest,total,original_months,
   original_rate,created_by,full_principal,interest_breakdown,calculated_total,principal_write_off,partial_interest_only,advance_to_principal)
 values(l.id,l.shop_id,on_date,(quote->>'months')::int,(quote->>'rate')::numeric,greatest(0,received-principal),
   received,(quote->>'original_months')::int,l.rate,auth.uid(),full_principal,quote->'breakdown',(quote->>'total')::numeric,greatest(0,principal-received),partial_interest_only,(quote->>'advance_to_principal')::numeric);
end
$$;
create or replace function public.record_release(loan uuid,on_date date,billed_months integer,monthly_rate numeric,
 full_principal boolean,expected_quote jsonb,received_amount numeric)
returns void language sql security definer set search_path='' as $$
 select public.record_release(loan,on_date,billed_months,monthly_rate,full_principal,
   case when expected_quote is null then null else expected_quote||jsonb_build_object('partial_interest_only',false) end,
   received_amount,false)
$$;

create or replace function private.record_loan_top_up(s uuid,loan uuid,payment_date date,principal numeric,bank uuid)
returns uuid language plpgsql set search_path='' as $$
declare l public.loans; saved_id uuid;
begin
 select * into l from public.loans where (shop_id,id)=(s,loan) for update;
 if not found or exists(select 1 from public.releases where loan_id=loan) then
   raise exception 'Select an open bill';
 end if;
 if payment_date is null or not isfinite(payment_date) or payment_date<l.loan_date or payment_date>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Payment date must be between the pledge date and today';
 end if;
 if principal is null or principal<=0 or principal>=1000000000000 or principal<>round(principal,2) then
   raise exception 'Enter a valid additional amount';
 end if;
 insert into public.loan_top_ups(shop_id,loan_id,paid_on,amount,payment_ledger_id,created_by)
 values(s,loan,payment_date,principal,bank,auth.uid()) returning id into saved_id;
 return saved_id;
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
 where p.interest_advance>0
 union all
 select r.shop_id,p.id,10,r.release_date,'Partial payment reclassified as interest '||l.bill,
   'Pawn loans','Interest income',p.principal_paid,null::uuid,null::uuid
 from public.releases r join public.loan_partial_payments p on (p.shop_id,p.loan_id)=(r.shop_id,r.loan_id)
 join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where r.partial_interest_only and p.principal_paid>0
 union all
 select r.shop_id,r.loan_id,11,r.release_date,'Advance applied to principal '||l.bill,
   'Interest income','Pawn loans',r.advance_to_principal,null::uuid,null::uuid
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where r.advance_to_principal>0;

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
 upper_date date := coalesce(to_date,(now() at time zone 'Asia/Kolkata')::date);
begin
 if from_date>(now() at time zone 'Asia/Kolkata')::date
   or upper_date>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Choose today or an earlier date';
 end if;
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
   from jsonb_array_elements(public.report_summary(s,kind,from_date,upper_date)) with ordinality as r(item,ordinal);
 else
   if kind='Loan balance' and page_cursor is null then
     summary := 'Outstanding principal '||private.report_inr((public.report_summary(s,kind,null,upper_date)->>'principal')::numeric);
   end if;
   with candidates as (
     select l.loan_date as entry_date,l.id,0 as line,jsonb_build_array(l.loan_date,l.bill,private.report_inr(l.amount),private.report_inr(l.advance_interest),private.report_inr(l.amount-l.advance_interest),coalesce(account.name,'Cash')) as cells
     from public.loans l left join public.ledgers account on (account.shop_id,account.id)=(l.shop_id,l.payment_ledger_id)
     where kind='Pledging' and l.shop_id=s and l.loan_date between lower_date and upper_date
       and (cursor_date is null or (l.loan_date,l.id)>(cursor_date,cursor_id))
     union all
     select t.paid_on,t.id,0,jsonb_build_array(t.paid_on,l.bill,private.report_inr(t.amount),
       private.report_inr(0),private.report_inr(t.amount),coalesce(account.name,'Cash'))
     from public.loan_top_ups t join public.loans l on (l.shop_id,l.id)=(t.shop_id,t.loan_id)
     left join public.ledgers account on (account.shop_id,account.id)=(t.shop_id,t.payment_ledger_id)
     where kind='Pledging' and t.shop_id=s and t.paid_on between lower_date and upper_date
       and (cursor_date is null or (t.paid_on,t.id)>(cursor_date,cursor_id))
     union all
     select r.release_date,r.loan_id,0,jsonb_build_array(r.release_date,l.bill,private.report_inr(r.total),private.report_inr(r.interest),coalesce(account.name,'Cash'))
     from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
     left join public.ledgers account on (account.shop_id,account.id)=(r.shop_id,r.payment_ledger_id)
     where kind='Releases' and r.shop_id=s and r.release_date between lower_date and upper_date
       and (cursor_date is null or (r.release_date,r.loan_id)>(cursor_date,cursor_id))
     union all
     select l.loan_date,l.id,0,jsonb_build_array(l.bill,l.loan_date,private.report_inr(l.amount+coalesce((
       select sum(t.amount) from public.loan_top_ups t
       where t.shop_id=l.shop_id and t.loan_id=l.id and t.paid_on<=upper_date
     ),0)-coalesce((
       select sum(p.principal_paid) from public.loan_partial_payments p
       where (p.shop_id,p.loan_id)=(l.shop_id,l.id) and p.paid_on<=upper_date
     ),0)))
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
 if (case operation when 'pledge' then (payload->>'loan_date')::date
     when 'journal' then (payload->>'entry_date')::date end)>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Choose today or an earlier date';
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
     if payload ? 'partial_interest_only' then
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,(payload->>'monthly_rate')::numeric,coalesce((payload->>'full_principal')::boolean,false),payload->'expected_quote',(payload->>'received_amount')::numeric,coalesce((payload->>'partial_interest_only')::boolean,false));
     else
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,(payload->>'monthly_rate')::numeric,coalesce((payload->>'full_principal')::boolean,false),payload->'expected_quote',(payload->>'received_amount')::numeric);
     end if;
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


