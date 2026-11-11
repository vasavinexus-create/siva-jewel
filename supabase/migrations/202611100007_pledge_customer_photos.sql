create index customers_photo_path_idx on public.customers(photo) where photo is not null;

create policy pledge_customer_photo_read on storage.objects for select to authenticated using (
  bucket_id='pawn-media' and split_part(name,'/',2)='customer'
  and exists (
    select 1 from public.customers c
    where c.shop_id::text=split_part(storage.objects.name,'/',1)
      and c.photo=storage.objects.name
      and (public.can_access(c.shop_id,'loans') or public.can_access(c.shop_id,'release'))
  )
);
