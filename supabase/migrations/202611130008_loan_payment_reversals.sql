create table public.loan_payment_reversals (
 id uuid primary key default gen_random_uuid(),
 shop_id uuid not null,
 loan_id uuid not null,
 original_id uuid not null unique,
 operation text not null,
 original jsonb not null,
 reason text not null,
 reversed_on date not null default ((now() at time zone 'Asia/Kolkata')::date),
 reversed_by uuid not null references auth.users,
 foreign key (shop_id,loan_id) references public.loans(shop_id,id)
);
alter table public.loan_payment_reversals enable row level security;
grant select on public.loan_payment_reversals to authenticated;
create policy loan_payment_reversals_read on public.loan_payment_reversals for select to authenticated using (
 public.can_access(shop_id,'audit') or public.can_access(shop_id,'accounting') or public.can_access(shop_id,'reports')
);

create function public.reverse_loan_payment(s uuid,loan uuid,entry uuid,reason text)
returns void language plpgsql security definer set search_path='' as $$
declare original jsonb; kind text; payment_date date;
begin
 if not public.can_access(s,'audit') then raise exception 'Audit access required'; end if;
 if nullif(trim(reason),'') is null then raise exception 'Enter a reversal reason'; end if;
 perform 1 from public.loans l where (l.shop_id,l.id)=(s,loan) for update;
 if not found or exists(select 1 from public.releases r where r.loan_id=loan) then
   raise exception 'Reversals require an open bill';
 end if;
 select to_jsonb(p),p.paid_on,'partial_payment' into original,payment_date,kind
 from public.loan_partial_payments p where (p.shop_id,p.loan_id,p.id)=(s,loan,entry);
 if not found then
   select to_jsonb(t),t.paid_on,'top_up' into original,payment_date,kind
   from public.loan_top_ups t where (t.shop_id,t.loan_id,t.id)=(s,loan,entry);
 end if;
 if original is null then raise exception 'Payment is unavailable or already reversed'; end if;
 if kind='top_up' and exists(select 1 from public.loan_partial_payments p
   where (p.shop_id,p.loan_id)=(s,loan) and p.paid_on>=payment_date and p.principal_paid>0) then
   raise exception 'Reverse dependent principal payments before reversing this top-up';
 end if;
 insert into public.loan_payment_reversals(shop_id,loan_id,original_id,operation,original,reason,reversed_by)
 values(s,loan,entry,kind,original,trim(reason),auth.uid());
 if kind='top_up' then delete from public.loan_top_ups where id=entry;
 else delete from public.loan_partial_payments where id=entry;
 end if;
end
$$;
revoke execute on function public.reverse_loan_payment(uuid,uuid,uuid,text) from public,anon;
grant execute on function public.reverse_loan_payment(uuid,uuid,uuid,text) to authenticated;

create function public.loan_payment_history(s uuid,loan uuid)
returns table(id uuid,paid_on date,kind text,amount numeric,reversed_on date,reason text,reversed_by uuid,staff_email text)
language sql stable security definer set search_path='' as $$
 select entries.*,staff.email from (
  select t.id,t.paid_on,'Top-up'::text,t.amount,null::date,null::text,null::uuid as actor from public.loan_top_ups t where (t.shop_id,t.loan_id)=(s,loan)
  union all
  select p.id,p.paid_on,'Partial payment',p.interest_advance+p.principal_paid,null,null,null from public.loan_partial_payments p where (p.shop_id,p.loan_id)=(s,loan)
  union all
  select r.original_id,(r.original->>'paid_on')::date,case when r.operation='top_up' then 'Top-up' else 'Partial payment' end,
    coalesce((r.original->>'amount')::numeric,(r.original->>'principal_paid')::numeric+(r.original->>'interest_advance')::numeric),
    r.reversed_on,r.reason,r.reversed_by from public.loan_payment_reversals r where (r.shop_id,r.loan_id)=(s,loan)
 ) entries left join public.staff staff on (staff.shop_id,staff.user_id)=(s,entries.actor)
 where public.can_access(s,'audit') order by 2 desc,1
$$;
revoke execute on function public.loan_payment_history(uuid,uuid) from public,anon;
grant execute on function public.loan_payment_history(uuid,uuid) to authenticated;

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
 where r.advance_to_principal>0
 union all
 select r.shop_id,r.id,entries.line,case when flip.reversed then r.reversed_on else (r.original->>'paid_on')::date end,
   (case when flip.reversed then 'Reversal ' else '' end)||entries.description||' '||l.bill,
   case when flip.reversed then entries.credit else entries.debit end,
   case when flip.reversed then entries.debit else entries.credit end,entries.amount,
   case when flip.reversed then entries.credit_id else entries.debit_id end,
   case when flip.reversed then entries.debit_id else entries.credit_id end
 from public.loan_payment_reversals r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 cross join lateral (select (r.original->>'payment_ledger_id')::uuid as id,
   case when r.original->>'payment_ledger_id' is null then 'Cash' else 'Other assets' end as account) bank
 cross join (values(false),(true)) flip(reversed)
 cross join lateral (values
   (case when flip.reversed then 16 else 13 end,'Top-up','Pawn loans',bank.account,(r.original->>'amount')::numeric,null::uuid,bank.id),
   (case when flip.reversed then 17 else 14 end,'Partial principal payment',bank.account,'Pawn loans',(r.original->>'principal_paid')::numeric,bank.id,null::uuid),
   (case when flip.reversed then 18 else 15 end,'Partial interest payment',bank.account,'Interest income',(r.original->>'interest_advance')::numeric,bank.id,null::uuid)
 ) entries(line,description,debit,credit,amount,debit_id,credit_id)
 where entries.amount>0;

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
    ),0)+coalesce((select sum(case when rev.operation='top_up' then (rev.original->>'amount')::numeric
         else -(rev.original->>'principal_paid')::numeric end)
       from public.loan_payment_reversals rev where (rev.shop_id,rev.loan_id)=(l.shop_id,l.id)
       and (rev.original->>'paid_on')::date<=coalesce(to_date,'infinity'::date) and rev.reversed_on>coalesce(to_date,'infinity'::date)),0)),0))
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
     ),0)+coalesce((select sum(case when rev.operation='top_up' then (rev.original->>'amount')::numeric
         else -(rev.original->>'principal_paid')::numeric end)
       from public.loan_payment_reversals rev where (rev.shop_id,rev.loan_id)=(l.shop_id,l.id)
       and (rev.original->>'paid_on')::date<=upper_date and rev.reversed_on>upper_date),0)))
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

