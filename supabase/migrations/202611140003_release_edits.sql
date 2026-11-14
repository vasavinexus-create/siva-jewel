create function private.calculate_release_quote(loan uuid,on_date date,billed_months integer,monthly_rate numeric,full_principal boolean,partial_interest_only boolean, editing boolean)
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
 if not editing and exists(select 1 from public.releases where loan_id=loan) then raise exception 'Loan has already been released'; end if;
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
 if exists(select 1 from public.loan_payment_reversals rev
   where (rev.shop_id,rev.loan_id)=(l.shop_id,l.id) and rev.reversed_on>on_date) then
   raise exception 'Release date must be on or after the last payment reversal';
 end if;
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


revoke execute on function private.calculate_release_quote(uuid,date,integer,numeric,boolean,boolean,boolean) from public,anon,authenticated;

create or replace function public.release_quote(loan uuid,on_date date,billed_months integer,monthly_rate numeric,full_principal boolean,partial_interest_only boolean)
returns jsonb language sql stable security definer set search_path='' as $$
 select private.calculate_release_quote(loan,on_date,billed_months,monthly_rate,full_principal,partial_interest_only,false)
$$;

create table private.release_edits (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null,
 loan_id uuid not null,
 edited_at timestamptz not null default now(),
 edited_by uuid not null references auth.users,
 reason text not null,
 previous_release jsonb not null,
 corrected_release jsonb not null,
 foreign key (shop_id,loan_id) references public.loans(shop_id,id)
);

create function public.edit_release(s uuid,loan uuid,expected jsonb,details jsonb)
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
   payment_ledger_id=bank,reviewed_at=null,reviewed_by=null
 where (r.shop_id,r.loan_id)=(s,loan)
 returning * into corrected;

 insert into private.release_edits(shop_id,loan_id,edited_by,reason,previous_release,corrected_release)
 values(s,loan,auth.uid(),edit_reason,to_jsonb(existing),to_jsonb(corrected));
end
$$;
revoke execute on function public.edit_release(uuid,uuid,jsonb,jsonb) from public,anon;
grant execute on function public.edit_release(uuid,uuid,jsonb,jsonb) to authenticated;
