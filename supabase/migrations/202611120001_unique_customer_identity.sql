create function private.customer_mobile_key(mobile text)
returns text language sql immutable strict set search_path='' as $$
 select nullif(regexp_replace(regexp_replace(mobile,'[^0-9]','','g'),'^(91|0)([0-9]{10})$','\2'),'')
$$;

create unique index customers_shop_mobile_unique
 on public.customers(shop_id,private.customer_mobile_key(mobile));

create table private.customer_aadhaar (
 shop_id uuid not null,
 customer_id uuid not null,
 number text not null check (number ~ '^[0-9]{12}$'),
 primary key(shop_id,customer_id),
 constraint customer_aadhaar_shop_number_unique unique(shop_id,number),
 foreign key(shop_id,customer_id) references public.customers(shop_id,id) on delete cascade
);
revoke all on private.customer_aadhaar from public,anon,authenticated;

create function public.create_customer(s uuid,details jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare
 customer uuid;
 mobile_key text := private.customer_mobile_key(details->>'mobile');
 aadhaar text := regexp_replace(coalesce(details->>'aadhaar_number',''),'[ -]','','g');
 constraint_name_found text;
begin
 if not public.can_access(s,'customers') then
   raise exception 'Customer creation access denied' using errcode='42501';
 end if;
 if nullif(trim(details->>'name'),'') is null or mobile_key is null then
   raise exception 'Name and mobile number are required' using errcode='22023';
 end if;
 if aadhaar<>'' and aadhaar !~ '^[0-9]{12}$' then
   raise exception 'Aadhaar number must contain 12 digits' using errcode='22023';
 end if;
 insert into public.customers(shop_id,name,village,address,mobile,reference,photo,aadhaar_photo)
 values(s,trim(details->>'name'),details->>'village',details->>'address',mobile_key,
   details->>'reference',details->>'photo',details->>'aadhaar_photo') returning id into customer;
 if aadhaar<>'' then
   insert into private.customer_aadhaar(shop_id,customer_id,number) values(s,customer,aadhaar);
 end if;
 return customer;
exception when unique_violation then
 get stacked diagnostics constraint_name_found=constraint_name;
 case constraint_name_found
 when 'customers_shop_mobile_unique' then
   raise exception 'This mobile number already belongs to a customer in this shop' using errcode='23505';
 when 'customer_aadhaar_shop_number_unique' then
   raise exception 'This Aadhaar number already belongs to a customer in this shop' using errcode='23505';
 else raise;
 end case;
end
$$;
revoke execute on function public.create_customer(uuid,jsonb) from public,anon;
grant execute on function public.create_customer(uuid,jsonb) to authenticated;
