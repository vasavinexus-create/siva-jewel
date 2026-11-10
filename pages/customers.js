import { mount, db, shop, escape, field, photo, money, result, form, upload, showPhoto, searchCustomers, paginated } from '../app.js';

mount('customers', async () => {
  form(field('name','Name')+field('village','Village','')+field('address','Address','')+field('mobile','Mobile','type="tel" required')+
    field('reference','Reference','')+photo('photo','Customer photo')+photo('aadhaar_photo','Aadhaar photo'),'Add customer',async data=>{
    data.photo=await upload('customer',data.photo);
    data.aadhaar_photo=await upload('identity',data.aadhaar_photo);
    await result(db.from('customers').insert({...data,shop_id:shop}));
  });
  const history=form(field('search','Search name or mobile','type="search"')+
    '<label>Customer history<select name="customer" required></select></label>','Show history',async ({customer:id})=>{
    const customer=await result(db.from('customers').select('name,mobile,address,village,reference,photo,aadhaar_photo')
      .eq('shop_id',shop).eq('id',id).single());
    const detail=document.querySelector('#history');
    detail.innerHTML='<h2>'+escape(customer.name)+'</h2><p>'+
      [customer.mobile,customer.address,customer.village,customer.reference].map(escape).join(' · ')+'</p><div data-photos></div><div data-loans></div>';
    const photos=detail.querySelector('[data-photos]');
    await Promise.all([
      showPhoto(photos,customer.photo,'Customer photo'),showPhoto(photos,customer.aadhaar_photo,'Aadhaar photo'),
      paginated(detail.querySelector('[data-loans]'),['Bill','Pledged','Principal','Released','Interest','Total'],
        (from,to)=>result(db.from('loans').select('bill,loan_date,amount,releases(release_date,interest,total)')
          .eq('shop_id',shop).eq('customer_id',id).order('loan_date',{ascending:false}).order('id').range(from,to)),
        l=>[l.bill,l.loan_date,money(l.amount),l.releases?.release_date,l.releases&&money(l.releases.interest),l.releases&&money(l.releases.total)])
    ]);
  },false);
  history.insertAdjacentHTML('afterend','<section id="history"></section>');
  await searchCustomers(history.elements.search,history.elements.customer);
});
