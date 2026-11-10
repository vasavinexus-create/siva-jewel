create index loans_shop_date_idx on public.loans(shop_id,loan_date,id);
create index pending_release_idx on public.releases(shop_id,release_date,loan_id)
 where reviewed_at is null and (rate<>original_rate or months<>original_months);

create view public.pending_releases with (security_invoker=true) as
 select r.shop_id,r.loan_id,l.bill,r.release_date,r.months,r.original_months,r.rate,r.original_rate
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 where r.reviewed_at is null and (r.rate<>r.original_rate or r.months<>r.original_months);

create function public.search_customers(s uuid, term text)
returns table(id uuid,name text,mobile text) language sql stable set search_path='' as $$
 select c.id,c.name,c.mobile from public.customers c
 where c.shop_id=s and strpos(lower(c.name||' '||c.mobile),lower(trim(term)))>0
 order by c.name,c.id limit 50
$$;

create function public.search_open_loans(s uuid, term text)
returns table(id uuid,bill text,customer text,exact_bill boolean) language sql stable set search_path='' as $$
 select l.id,l.bill,c.name,lower(l.bill)=lower(trim(term))
 from public.loans l join public.customers c on (c.shop_id,c.id)=(l.shop_id,l.customer_id)
 where l.shop_id=s and public.can_access(s,'release')
 and not exists(select 1 from public.releases r where r.loan_id=l.id)
 and (strpos(lower(l.bill),lower(trim(term)))>0 or strpos(lower(c.name||' '||c.mobile),lower(trim(term)))>0)
 order by 4 desc,l.loan_date desc,l.id limit 50
$$;

create function public.release_quote(loan uuid,on_date date,billed_months integer default null,monthly_rate numeric default null)
returns jsonb language plpgsql stable set search_path='' as $$
declare
 l public.loans;
 m integer;
 charged integer;
 applied_rate numeric;
 interest numeric;
begin
 select * into l from public.loans where id=loan;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 if exists(select 1 from public.releases where loan_id=loan) then raise exception 'Loan has already been released'; end if;
 if on_date is null or on_date<l.loan_date then raise exception 'Release date must be on or after the pledge date'; end if;
 m := (extract(year from on_date)::int-extract(year from l.loan_date)::int)*12
      + extract(month from on_date)::int-extract(month from l.loan_date)::int;
 if (l.loan_date+make_interval(months=>m))::date<on_date then m:=m+1; end if;
 charged := coalesce(billed_months,m);
 applied_rate := round(coalesce(monthly_rate,l.rate),4);
 if charged<0 or applied_rate<0 or applied_rate>=10000 then raise exception 'Invalid months or rate'; end if;
 interest := round(l.amount*charged*applied_rate/100,2);
 return jsonb_build_object('bill',l.bill,'loan_date',l.loan_date,'grams',l.grams,'notes',l.notes,'photo',l.photo,
   'amount',l.amount,'months',charged,'rate',applied_rate,'interest',interest,'total',l.amount+interest,'original_months',m);
end
$$;

create or replace function public.record_release(loan uuid,on_date date,billed_months integer,monthly_rate numeric)
returns void language plpgsql security definer set search_path='' as $$
declare l public.loans; quote jsonb;
begin
 select * into l from public.loans where id=loan for update;
 if not found or not public.can_access(l.shop_id,'release') then raise exception 'Loan unavailable'; end if;
 quote := public.release_quote(loan,on_date,billed_months,monthly_rate);
 insert into public.releases(loan_id,shop_id,release_date,months,rate,interest,total,original_months,original_rate,created_by)
 values(l.id,l.shop_id,on_date,(quote->>'months')::int,(quote->>'rate')::numeric,(quote->>'interest')::numeric,
   (quote->>'total')::numeric,(quote->>'original_months')::int,l.rate,auth.uid());
end
$$;

create view public.ledger_entries with (security_invoker=true) as
 select shop_id,id,1 as line,loan_date as entry_date,'Pledge '||bill as description,
   'Pawn loans'::text as debit,'Cash'::text as credit,amount from public.loans
 union all
 select r.shop_id,r.loan_id,2,r.release_date,'Release '||l.bill,'Cash','Pawn loans',l.amount
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
 union all
 select r.shop_id,r.loan_id,3,r.release_date,'Release '||l.bill,'Cash','Interest income',r.interest
 from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id) where r.interest<>0
 union all
 select shop_id,id,4,entry_date,description,debit,credit,amount from public.journal;

create function public.report_summary(s uuid,kind text,from_date date,to_date date)
returns jsonb language plpgsql stable set search_path='' as $$
declare b jsonb; profit numeric; assets numeric;
begin
 if not public.can_access(s,'reports') then raise exception 'Report access denied'; end if;
 if kind='Loan balance' then
   return (select jsonb_build_object('principal',coalesce(sum(l.amount),0))
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

create function public.outstanding_loans(s uuid,to_date date)
returns table(id uuid,bill text,loan_date date,amount numeric) language sql stable set search_path='' as $$
 select l.id,l.bill,l.loan_date,l.amount from public.loans l where l.shop_id=s and public.can_access(s,'reports')
 and (to_date is null or l.loan_date<=to_date)
 and not exists(select 1 from public.releases r where r.loan_id=l.id and (to_date is null or r.release_date<=to_date))
$$;

revoke all on public.pending_releases,public.ledger_entries from public,anon;
grant select on public.pending_releases,public.ledger_entries to authenticated;
revoke execute on function public.search_customers(uuid,text),public.search_open_loans(uuid,text),
 public.release_quote(uuid,date,integer,numeric),public.report_summary(uuid,text,date,date),public.outstanding_loans(uuid,date) from public,anon;
grant execute on function public.search_customers(uuid,text),public.search_open_loans(uuid,text),
 public.release_quote(uuid,date,integer,numeric),public.report_summary(uuid,text,date,date),public.outstanding_loans(uuid,date) to authenticated;
