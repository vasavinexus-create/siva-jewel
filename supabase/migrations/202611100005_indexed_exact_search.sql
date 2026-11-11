create or replace function public.search_customers(s uuid, term text)
returns table(id uuid,name text,mobile text) language plpgsql stable security definer set search_path='' as $$
declare
 query text := lower(trim(term));
 digits text := regexp_replace(term,'[^0-9]','','g');
 pattern text := '%'||replace(replace(replace(query,'!','!!'),'%','!%'),'_','!_')||'%';
begin
 if not (public.can_access(s,'customers') or public.can_access(s,'loans')
   or public.can_access(s,'release') or public.can_access(s,'reports')) then return; end if;
 if query ~ '^[+0-9() .-]+$' and digits<>'' then
   return query select c.id,c.name,c.mobile from public.customers c
   where c.shop_id=s and regexp_replace(c.mobile,'[^0-9]','','g')=digits
   order by c.name,c.id limit 50;
   if found then return; end if;
 end if;
 return query select c.id,c.name,c.mobile from public.customers c
 where c.shop_id=s and (query='' or lower(c.name||' '||c.mobile) like pattern escape '!')
 order by c.name,c.id limit 50;
end
$$;

create or replace function public.search_open_loans(s uuid, term text)
returns table(id uuid,bill text,customer text,exact_bill boolean) language plpgsql stable security definer set search_path='' as $$
declare
 query text := lower(trim(term));
 digits text := regexp_replace(term,'[^0-9]','','g');
 pattern text := '%'||replace(replace(replace(query,'!','!!'),'%','!%'),'_','!_')||'%';
begin
 if not public.can_access(s,'release') then return; end if;
 return query
 select l.id,l.bill,c.name,true from public.loans l
 join public.customers c on (c.shop_id,c.id)=(l.shop_id,l.customer_id)
 where l.shop_id=s and lower(l.bill)=query
 and not exists(select 1 from public.releases r where r.loan_id=l.id)
 order by l.loan_date desc,l.id limit 50;
 if found then return; end if;
 if query ~ '^[+0-9() .-]+$' and digits<>'' then
   return query
   select l.id,l.bill,c.name,false from public.customers c
   join public.loans l on (l.shop_id,l.customer_id)=(c.shop_id,c.id)
   where c.shop_id=s and regexp_replace(c.mobile,'[^0-9]','','g')=digits
   and not exists(select 1 from public.releases r where r.loan_id=l.id)
   order by l.loan_date desc,l.id limit 50;
   if found then return; end if;
 end if;
 return query
 select l.id,l.bill,c.name,false
 from public.loans l join public.customers c on (c.shop_id,c.id)=(l.shop_id,l.customer_id)
 where l.shop_id=s
 and (query='' or l.id in (
   select match.id from public.loans match where match.shop_id=s and lower(match.bill) like pattern escape '!'
   union
   select match.id from public.customers person join public.loans match
     on (match.shop_id,match.customer_id)=(person.shop_id,person.id)
   where person.shop_id=s and lower(person.name||' '||person.mobile) like pattern escape '!'
 ))
 and not exists(select 1 from public.releases r where r.loan_id=l.id)
 order by l.loan_date desc,l.id limit 50;
end
$$;
