create index loan_payment_reversals_bill_date_idx
 on public.loan_payment_reversals(shop_id,loan_id,reversed_on);

create index ledgers_shop_picker_idx on public.ledgers(shop_id,name,id);
create index ledger_groups_shop_picker_idx on public.ledger_groups(shop_id,name,id);

create or replace function public.report_summary(s uuid,kind text,from_date date,to_date date)
returns jsonb language plpgsql stable set search_path='' as $$
declare b jsonb; profit numeric; assets numeric;
begin
 if not public.can_access(s,'reports') then raise exception 'Report access denied'; end if;
 if kind='Loan balance' then
   return (
     with open_loans as materialized (
       select l.id,l.amount from public.loans l
       where l.shop_id=s and l.loan_date<=coalesce(to_date,'infinity'::date)
       and not exists(select 1 from public.releases r where r.loan_id=l.id
         and r.release_date<=coalesce(to_date,'infinity'::date))
     ), principal_changes as (
       select l.amount from open_loans l
       union all
       select t.amount from public.loan_top_ups t join open_loans l on l.id=t.loan_id
       where t.shop_id=s and t.paid_on<=coalesce(to_date,'infinity'::date)
       union all
       select -p.principal_paid from public.loan_partial_payments p join open_loans l on l.id=p.loan_id
       where p.shop_id=s and p.paid_on<=coalesce(to_date,'infinity'::date)
       union all
       select case when rev.operation='top_up' then (rev.original->>'amount')::numeric
         else -(rev.original->>'principal_paid')::numeric end
       from public.loan_payment_reversals rev join open_loans l on l.id=rev.loan_id
       where rev.shop_id=s and rev.reversed_on>coalesce(to_date,'infinity'::date)
         and (rev.original->>'paid_on')::date<=coalesce(to_date,'infinity'::date)
     )
     select jsonb_build_object('principal',coalesce(sum(amount),0)) from principal_changes
   );
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

-- Run in each deployment using that project's Edge Function URL from Vault.
select cron.schedule('siva-jewel-expire-photos','17 * * * *',$job$
 select net.http_post(
   url:=endpoint.decrypted_secret,
   headers:=jsonb_build_object('Content-Type','application/json','x-cleanup-token',token.decrypted_secret),
   timeout_milliseconds:=30000
 )
 from vault.decrypted_secrets endpoint cross join vault.decrypted_secrets token
 where endpoint.name='siva_jewel_photo_cleanup_url' and endpoint.decrypted_secret like 'https://%'
   and token.name='siva_jewel_photo_cleanup'
$job$);
