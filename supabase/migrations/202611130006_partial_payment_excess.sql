create or replace function private.record_loan_partial_payment(s uuid,loan uuid,payment_date date,advance numeric,principal numeric,interest_only boolean,bank uuid)
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
 select l.amount+coalesce((select sum(t.amount) from public.loan_top_ups t
   where (t.shop_id,t.loan_id)=(s,loan) and t.paid_on<=payment_date),0)
   -coalesce((select sum(p.principal_paid) from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(s,loan) and p.paid_on<=payment_date),0)
 into balance;
 if principal>balance then
   advance := advance+(principal-balance);
   principal := balance;
 end if;
 if principal>0 and exists(select 1 from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(s,loan) and p.paid_on>payment_date and p.principal_paid>0) then
   raise exception 'Principal payments must be entered in date order';
 end if;
 insert into public.loan_partial_payments(shop_id,loan_id,paid_on,interest_advance,principal_paid,payment_ledger_id,created_by)
 values(s,loan,payment_date,advance,principal,bank,auth.uid()) returning id into saved_id;
 return saved_id;
end
$$;
