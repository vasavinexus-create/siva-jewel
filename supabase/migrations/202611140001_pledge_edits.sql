alter policy ledger_groups_read on public.ledger_groups using (
  public.can_access(shop_id,'accounting') or public.can_access(shop_id,'journal') or public.can_access(shop_id,'reports')
  or (category='Bank' and (public.can_access(shop_id,'loans') or public.can_access(shop_id,'release')))
);
alter policy ledgers_read on public.ledgers using (
  public.can_access(shop_id,'accounting') or public.can_access(shop_id,'journal') or public.can_access(shop_id,'reports')
  or exists(select 1 from public.ledger_groups g where (g.shop_id,g.id)=(ledgers.shop_id,ledgers.group_id) and g.category='Bank')
);

create table private.pledge_edits (
  id bigint generated always as identity primary key,
  shop_id uuid not null,
  loan_id uuid not null,
  edited_by uuid not null,
  edited_at timestamptz not null default now(),
  prior_details jsonb not null,
  corrected_details jsonb not null
);

create function public.edit_pledge(s uuid, loan uuid, changes jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
 current_loan public.loans%rowtype;
 corrected public.loans%rowtype;
begin
 if not public.can_access(s,'loans') or not (
   public.can_access(s,'pledge_edit_all') or public.can_access(s,'pledge_edit_details')
 ) then raise exception 'Pledge edit access denied' using errcode='42501'; end if;

 select * into current_loan from public.loans where (shop_id,id)=(s,loan) for update;
 if not found then raise exception 'Bill unavailable'; end if;

 corrected := jsonb_populate_record(current_loan, changes);
 corrected.bill := btrim(corrected.bill);
 if coalesce(corrected.bill,'')='' or corrected.customer_id is null or corrected.grams is null then
   raise exception 'Bill number, customer and grams are required';
 end if;
 if corrected.photo is distinct from current_loan.photo and corrected.photo is not null and
   (corrected.photo not like s::text||'/jewel/%' or not exists (
     select 1 from storage.objects where bucket_id='pawn-media' and name=corrected.photo
   )) then raise exception 'Jewel photo unavailable'; end if;

 if row(corrected.amount,corrected.rate,corrected.loan_date,corrected.advance_interest,corrected.payment_ledger_id)
    is distinct from row(current_loan.amount,current_loan.rate,current_loan.loan_date,current_loan.advance_interest,current_loan.payment_ledger_id) then
   if not public.can_access(s,'pledge_edit_all') then
     raise exception 'Financial edit access denied' using errcode='42501';
   end if;
   if exists(select 1 from public.releases where (shop_id,loan_id)=(s,loan))
      or exists(select 1 from public.loan_partial_payments where (shop_id,loan_id)=(s,loan))
      or exists(select 1 from public.loan_top_ups where (shop_id,loan_id)=(s,loan))
      or exists(select 1 from public.loan_payment_reversals where (shop_id,loan_id)=(s,loan)) then
     raise exception 'Financial details are locked because this bill has linked transactions';
   end if;
   if corrected.loan_date is null or corrected.loan_date>(now() at time zone 'Asia/Kolkata')::date
      or corrected.amount is null or corrected.amount<=0 or corrected.rate is null or corrected.rate<0
      or corrected.advance_interest is null or corrected.advance_interest<0 or corrected.advance_interest>=corrected.amount then
     raise exception 'Invalid pledge date, principal, rate or advance interest';
   end if;
   perform private.payment_bank_ledger(s,case when corrected.payment_ledger_id is null then 'cash' else 'bank' end,corrected.payment_ledger_id);
 end if;

 update public.loans set bill=corrected.bill, customer_id=corrected.customer_id, grams=corrected.grams,
   notes=corrected.notes, photo=corrected.photo, amount=corrected.amount, rate=corrected.rate,
   loan_date=corrected.loan_date, advance_interest=corrected.advance_interest,
   payment_ledger_id=corrected.payment_ledger_id
 where (shop_id,id)=(s,loan)
 returning * into corrected;
 if corrected is distinct from current_loan then
   insert into private.pledge_edits(shop_id,loan_id,edited_by,prior_details,corrected_details)
   values(s,loan,auth.uid(),to_jsonb(current_loan),to_jsonb(corrected));
 end if;
end
$$;
revoke execute on function public.edit_pledge(uuid,uuid,jsonb) from public,anon;
grant execute on function public.edit_pledge(uuid,uuid,jsonb) to authenticated;

create function public.search_pledge_edits(s uuid, term text)
returns table(id uuid,bill text,customer text)
language sql stable security definer set search_path='' as $$
 select l.id,l.bill,c.name
 from public.loans l join public.customers c on (c.shop_id,c.id)=(l.shop_id,l.customer_id)
 where l.shop_id=s and public.can_access(s,'loans')
   and (l.bill ilike btrim(term)||'%' or l.bill=term)
 order by (l.bill=term) desc,l.bill limit 20
$$;
revoke execute on function public.search_pledge_edits(uuid,text) from public,anon;
grant execute on function public.search_pledge_edits(uuid,text) to authenticated;
