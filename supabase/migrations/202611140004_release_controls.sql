revoke execute on function public.record_release(uuid,date,integer,numeric),
 public.review_release(uuid) from public,anon,authenticated;

alter table public.shops add column accounting_closed_through date;
alter table public.releases add column correction_pending boolean not null default false;

create function public.set_release_closed_through(s uuid, closed_through date)
returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.can_access(s,'admin') then
   raise exception 'Shop admin access required' using errcode='42501';
 end if;
 if closed_through>(now() at time zone 'Asia/Kolkata')::date then
   raise exception 'Choose today or an earlier date';
 end if;
 update public.shops set accounting_closed_through=closed_through where id=s;
end
$$;
revoke execute on function public.set_release_closed_through(uuid,date) from public,anon;
grant execute on function public.set_release_closed_through(uuid,date) to authenticated;

create function private.check_release_period(s uuid, previous_date date, corrected_date date)
returns void language plpgsql set search_path='' as $$
declare closed_through date;
begin
 select accounting_closed_through into closed_through from public.shops where id=s for share;
 if previous_date<=closed_through or corrected_date<=closed_through then
   raise exception 'Release accounting is closed through %',closed_through;
 end if;
end
$$;

create or replace view public.pending_releases with (security_invoker=true) as
 select r.shop_id,r.loan_id,l.bill,r.release_date,r.months,r.original_months,r.rate,r.original_rate,
   r.calculated_total,r.total as received_amount,r.principal_write_off,r.interest_shortfall,
   r.short_payment_reason,r.correction_pending
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where public.can_access(r.shop_id,'audit') and r.reviewed_at is null
 and (r.rate<>r.original_rate or r.months<>r.original_months or r.total<r.calculated_total or r.correction_pending);

create index pending_release_correction_idx on public.releases(shop_id,release_date,loan_id)
 where correction_pending and reviewed_at is null;

create index release_edits_bill_idx on private.release_edits(shop_id,loan_id,edited_at desc,id desc);
create function public.release_correction_history(s uuid,loan uuid,before_time timestamptz default null,before_id uuid default null)
returns table(id uuid,edited_at timestamptz,actor text,reason text,previous_release jsonb,corrected_release jsonb)
language sql stable security definer set search_path='' as $$
 select e.id,e.edited_at,coalesce(staff.email,e.edited_by::text),e.reason,e.previous_release,e.corrected_release
 from private.release_edits e left join public.staff staff on (staff.shop_id,staff.user_id)=(e.shop_id,e.edited_by)
 where public.can_access(s,'audit') and (e.shop_id,e.loan_id)=(s,loan)
   and (before_time is null or (e.edited_at,e.id)<(before_time,before_id))
 order by e.edited_at desc,e.id desc limit 51
$$;
revoke execute on function public.release_correction_history(uuid,uuid,timestamptz,uuid) from public,anon;
grant execute on function public.release_correction_history(uuid,uuid,timestamptz,uuid) to authenticated;

create or replace function public.edit_release(s uuid,loan uuid,expected jsonb,details jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
 existing public.releases;
 corrected public.releases;
 quote jsonb;
 principal numeric;
 received numeric := (details->>'received_amount')::numeric;
 paid_on date := (details->>'release_date')::date;
 months integer := (details->>'months')::integer;
 rate numeric := (details->>'rate')::numeric;
 short_reason text := nullif(trim(details->>'short_payment_reason'),'');
 edit_reason text := nullif(trim(details->>'reason'),'');
 bank uuid;
 charge_full_principal boolean := coalesce((details->>'full_principal')::boolean,false);
 treat_partials_as_interest boolean := coalesce((details->>'partial_interest_only')::boolean,false);
begin
 if not (public.can_access(s,'release') and public.can_access(s,'release_edit')) then
   raise exception 'Release edit access denied' using errcode='42501';
 end if;
 if edit_reason is null then raise exception 'Enter a reason for the correction'; end if;
 if received is null or received<0 or received>=10000000000000000 or received<>round(received,2) then
   raise exception 'Enter a valid received amount with up to two decimal places';
 end if;
 if months is null or rate is null then raise exception 'Months and rate are required'; end if;

 perform 1 from public.loans where (shop_id,id)=(s,loan) for update;
 select * into existing from public.releases where (shop_id,loan_id)=(s,loan) for update;
 if not found then raise exception 'Release unavailable'; end if;
 perform private.check_release_period(s,existing.release_date,paid_on);
 if expected is distinct from to_jsonb(existing) then
   raise exception 'This release changed. Look up the bill again before saving.';
 end if;
 bank := private.payment_bank_ledger(s,details->>'payment_mode',nullif(details->>'payment_ledger_id','')::uuid);
 quote := private.calculate_release_quote(loan,paid_on,months,rate,charge_full_principal,treat_partials_as_interest,true);
 principal := (quote->>'amount')::numeric;
 if received<(quote->>'total')::numeric and short_reason is null then
   raise exception 'Enter a reason for the short payment';
 end if;

 update public.releases r set release_date=paid_on,months=(quote->>'months')::integer,rate=(quote->>'rate')::numeric,
   full_principal=charge_full_principal,partial_interest_only=treat_partials_as_interest,
   original_months=(quote->>'original_months')::integer,
   total=received,interest=greatest(0,received-principal),interest_breakdown=quote->'breakdown',
   calculated_total=(quote->>'total')::numeric,principal_write_off=greatest(0,principal-received),
   advance_to_principal=(quote->>'advance_to_principal')::numeric,
   short_payment_reason=case when received<(quote->>'total')::numeric then short_reason end,
   interest_shortfall=greatest(0,(quote->>'interest')::numeric-greatest(0,received-principal)),
   excess_interest=greatest(0,received-(quote->>'total')::numeric)+(quote->>'excess_advance')::numeric,
   payment_ledger_id=bank,reviewed_at=null,reviewed_by=null,correction_pending=true
 where (r.shop_id,r.loan_id)=(s,loan)
 returning * into corrected;

 insert into private.release_edits(shop_id,loan_id,edited_by,reason,previous_release,corrected_release)
 values(s,loan,auth.uid(),edit_reason,to_jsonb(existing),to_jsonb(corrected));
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
 permission := case operation when 'pledge' then 'loans' when 'top_up' then 'loans' when 'journal' then 'journal'
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
     perform private.check_release_period(s,null,(payload->>'on_date')::date);
     if payload->>'billed_months' is null or payload->>'monthly_rate' is null then raise exception 'Months and rate are required'; end if;
     if jsonb_typeof(payload->'expected_quote') is distinct from 'object' then
       raise exception 'Refresh the release quote before recording the release';
     end if;
     perform public.record_release(target,(payload->>'on_date')::date,(payload->>'billed_months')::int,
       (payload->>'monthly_rate')::numeric,coalesce((payload->>'full_principal')::boolean,false),
       payload->'expected_quote',(payload->>'received_amount')::numeric,
       coalesce((payload->>'partial_interest_only')::boolean,false),payload->>'short_payment_reason');
     if bank is not null then update public.releases set payment_ledger_id=bank where loan_id=target; end if;
   else
     update public.releases r set reviewed_at=now(),reviewed_by=request_actor,correction_pending=false
     where r.shop_id=s and r.loan_id=target and r.reviewed_at is null
       and (r.rate<>r.original_rate or r.months<>r.original_months or r.total<r.calculated_total or r.correction_pending);
     if not found then raise exception 'Release is no longer pending'; end if;
   end if;
 end if;
 update private.financial_requests f set record_id=target
 where (f.shop_id,f.actor,f.request_id)=(s,request_actor,submit_financial.request_id);
 return target;
end
$$;
