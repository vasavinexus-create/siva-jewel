create function public.edit_customer(s uuid, customer uuid, details jsonb)
returns void language plpgsql security definer set search_path='' as $$
declare
 existing public.customers%rowtype;
 corrected public.customers%rowtype;
 aadhaar text := regexp_replace(coalesce(details->>'aadhaar_number',''),'[ -]','','g');
 violated_constraint text;
begin
 if not (public.can_access(s,'customers') and public.can_access(s,'customer_edit')) then
   raise exception 'Customer edit access denied' using errcode='42501';
 end if;
 select * into existing from public.customers where (shop_id,id)=(s,customer) for update;
 if not found then raise exception 'Customer unavailable'; end if;
 corrected := jsonb_populate_record(existing,details);
 corrected.name := trim(corrected.name);
 corrected.mobile := private.customer_mobile_key(corrected.mobile);
 if coalesce(corrected.name,'')='' or corrected.mobile is null then
   raise exception 'Name and mobile number are required';
 end if;
 if aadhaar<>'' and aadhaar !~ '^[0-9]{12}$' then
   raise exception 'Aadhaar number must contain 12 digits';
 end if;
 if exists (
   select 1 from (values
     (corrected.photo,existing.photo,'customer'),
     (corrected.aadhaar_photo,existing.aadhaar_photo,'identity')
   ) as media(path,old_path,category)
   where path is distinct from old_path and path is not null
     and (path not like s::text||'/'||category||'/%' or not exists (
       select 1 from storage.objects where bucket_id='pawn-media' and name=path
     ))
 ) then raise exception 'Customer photo unavailable'; end if;

 update public.customers set name=corrected.name,mobile=corrected.mobile,
   address=corrected.address,village=corrected.village,reference=corrected.reference,
   photo=corrected.photo,aadhaar_photo=corrected.aadhaar_photo
 where (shop_id,id)=(s,customer);
 if aadhaar<>'' then
   insert into private.customer_aadhaar(shop_id,customer_id,number) values(s,customer,aadhaar)
   on conflict (shop_id,customer_id) do update set number=excluded.number;
 end if;
exception when unique_violation then
 get stacked diagnostics violated_constraint=constraint_name;
 case violated_constraint
 when 'customers_shop_mobile_unique' then
   raise exception 'This mobile number already belongs to a customer in this shop' using errcode='23505';
 when 'customer_aadhaar_shop_number_unique' then
   raise exception 'This Aadhaar number already belongs to a customer in this shop' using errcode='23505';
 else raise;
 end case;
end
$$;
revoke execute on function public.edit_customer(uuid,uuid,jsonb) from public,anon;
grant execute on function public.edit_customer(uuid,uuid,jsonb) to authenticated;
