import { mount, db, shop, escape, field, photo, money, result, form, upload, showPhoto, lookupField, searchCustomers, paginated, fetchCursor } from '../app.js';

mount('customers', async () => {
  form(field('name','Name')+field('village','Village','')+field('address','Address','')+field('mobile','Mobile','type="tel" required')+
    field('reference','Reference','')+
    field('aadhaar_number','Aadhaar number (optional)','inputmode="numeric" autocomplete="off" maxlength="14" placeholder="12 digits"')+photo('photo','Customer photo')+photo('aadhaar_photo','Aadhaar photo'),'Add customer',async data=>{
    data.photo=await upload('customer',data.photo);
    data.aadhaar_photo=await upload('identity',data.aadhaar_photo);
    await result(db.rpc('create_customer',{s:shop,details:data}));
  });
  const history=form(lookupField('customer','Customer history','Type a name or mobile number'),'Show history',async ({customer:id})=>{
    const customer=await result(db.from('customers').select('name,mobile,address,village,reference,photo,aadhaar_photo')
      .eq('shop_id',shop).eq('id',id).single());
    const detail=document.querySelector('#history');
    detail.innerHTML='<h2>'+escape(customer.name)+'</h2><p>'+
      [customer.mobile,customer.address,customer.village,customer.reference].map(escape).join(' · ')+'</p><div data-photos></div><div data-loans></div>';
    const photos=detail.querySelector('[data-photos]');
    await Promise.all([
      showPhoto(photos,customer.photo,'Customer photo'),showPhoto(photos,customer.aadhaar_photo,'Aadhaar photo'),
      paginated(detail.querySelector('[data-loans]'),['Bill','Pledged','Principal','Advance interest','Released','Interest at release','Total at release'],
        cursor=>fetchCursor(db.from('loans').select('id,bill,loan_date,amount,advance_interest,releases(release_date,interest,total)')
          .eq('shop_id',shop).eq('customer_id',id),[['loan_date',false],['id',true]],cursor),
        l=>[l.bill,l.loan_date,money(l.amount),money(l.advance_interest),l.releases?.release_date,l.releases&&money(l.releases.interest),l.releases&&money(l.releases.total)])
    ]);
  },false);
  history.insertAdjacentHTML('afterend','<section id="history"></section>');
  searchCustomers(history,'customer');
});
