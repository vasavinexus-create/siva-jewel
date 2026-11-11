create function private.report_inr(amount numeric)
returns text language plpgsql immutable strict set search_path='' as $$
declare
 decimal_parts text[] := string_to_array(round(abs(amount),2)::text,'.');
 digits text := decimal_parts[1];
 formatted text := right(digits,3);
begin
 digits := left(digits,greatest(length(digits)-3,0));
 while length(digits)>0 loop
   formatted := right(digits,2)||','||formatted;
   digits := left(digits,greatest(length(digits)-2,0));
 end loop;
 return (case when amount<0 then '-' else '' end)||chr(8377)||formatted||'.'||rpad(coalesce(decimal_parts[2],''),2,'0');
end
$$;

create function public.run_report(s uuid,kind text,from_date date,to_date date,page_cursor jsonb default null)
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
 upper_date date := coalesce(to_date,'infinity'::date);
begin
 if not public.can_access(s,'reports') then raise exception 'Report access denied' using errcode='42501'; end if;
 if from_date>to_date then raise exception 'The start date must be on or before the end date.' using errcode='22023'; end if;
 if page_cursor is not null and (cursor_date is null or cursor_id is null or cursor_line is null) then
   raise exception 'Invalid report cursor' using errcode='22023';
 end if;
 case kind
 when 'Trial balance' then headers := array['Account','Debit balance','Credit balance'];
 when 'Profit and loss','Balance sheet' then headers := array['Account','Amount'];
 when 'Loan balance' then headers := array['Bill','Date','Principal'];
 when 'Pledging' then headers := array['Date','Bill','Cash out'];
 when 'Releases' then headers := array['Date','Bill','Cash in','Interest'];
 when 'Day book','General ledger' then headers := array['Date','Entry','Debit','Credit','Amount'];
 else raise exception 'Unknown report' using errcode='22023';
 end case;

 if kind in ('Trial balance','Profit and loss','Balance sheet') then
   select jsonb_agg(
     case when kind='Trial balance' then jsonb_build_array(item->>0,private.report_inr((item->>1)::numeric),private.report_inr((item->>2)::numeric))
     else jsonb_build_array(item->>0,private.report_inr((item->>1)::numeric)) end order by ordinal)
   into report_rows
   from jsonb_array_elements(public.report_summary(s,kind,from_date,to_date)) with ordinality as r(item,ordinal);
 else
   if kind='Loan balance' and page_cursor is null then
     summary := 'Outstanding principal '||private.report_inr((public.report_summary(s,kind,null,to_date)->>'principal')::numeric);
   end if;
   with candidates as (
     select l.loan_date as entry_date,l.id,0 as line,jsonb_build_array(l.loan_date,l.bill,private.report_inr(l.amount)) as cells
     from public.loans l
     where kind='Pledging' and l.shop_id=s and l.loan_date between lower_date and upper_date
       and (cursor_date is null or (l.loan_date,l.id)>(cursor_date,cursor_id))
     union all
     select r.release_date,r.loan_id,0,jsonb_build_array(r.release_date,l.bill,private.report_inr(r.total),private.report_inr(r.interest))
     from public.releases r join public.loans l on (l.shop_id,l.id)=(r.shop_id,r.loan_id)
     where kind='Releases' and r.shop_id=s and r.release_date between lower_date and upper_date
       and (cursor_date is null or (r.release_date,r.loan_id)>(cursor_date,cursor_id))
     union all
     select l.loan_date,l.id,0,jsonb_build_array(l.bill,l.loan_date,private.report_inr(l.amount))
     from public.loans l
     where kind='Loan balance' and l.shop_id=s and l.loan_date<=upper_date
       and (cursor_date is null or (l.loan_date,l.id)>(cursor_date,cursor_id))
       and not exists(select 1 from public.releases r where r.loan_id=l.id and r.release_date<=upper_date)
     union all
     select e.entry_date,e.id,e.line,jsonb_build_array(e.entry_date,e.description,e.debit,e.credit,private.report_inr(e.amount))
     from public.ledger_entries e
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

revoke execute on function private.report_inr(numeric),public.run_report(uuid,text,date,date,jsonb) from public,anon;
grant execute on function public.run_report(uuid,text,date,date,jsonb) to authenticated;
