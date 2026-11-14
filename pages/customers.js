import { mount, db, shop, escape, field, photo, money, result, form, upload, showPhoto, lookupField, searchCustomers, paginated, fetchCursor } from '../app.js';

const customerFields=field('name','Name')+field('village','Village','')+field('address','Address','')+
  field('mobile','Mobile','type="tel" required')+field('reference','Reference','');
const aadhaarField=label=>field('aadhaar_number',label,'inputmode="numeric" autocomplete="off" maxlength="14" placeholder="12 digits"');
const customerColumns='name,mobile,address,village,reference,photo,aadhaar_photo';

mount('customers', async () => {
  const main=document.querySelector('main');
  main.insertAdjacentHTML('beforeend',`
    <div class="owner-tabs" role="tablist" aria-label="Customers">
      <button type="button" role="tab" id="customer-list-tab" aria-controls="customer-list" aria-selected="true">Customers</button>
      <button type="button" role="tab" id="customer-edit-tab" aria-controls="customer-edit" aria-selected="false" tabindex="-1" hidden>Edit customer</button>
    </div>
    <div id="customer-list" role="tabpanel" aria-labelledby="customer-list-tab"></div>
    <div id="customer-edit" role="tabpanel" aria-labelledby="customer-edit-tab" hidden></div>
  `);
  const list=main.querySelector('#customer-list');
  form(customerFields+aadhaarField('Aadhaar number (optional)')+photo('photo','Customer photo')+photo('aadhaar_photo','Aadhaar photo'),'Add customer',async data=>{
    data.photo=await upload('customer',data.photo);
    data.aadhaar_photo=await upload('identity',data.aadhaar_photo);
    await result(db.rpc('create_customer',{s:shop,details:data}));
  },true,list);
  const history=form(lookupField('customer','Customer history','Type a name or mobile number'),'Show history',async ({customer:id})=>{
    const customer=await result(db.from('customers').select(customerColumns)
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
  },false,list);
  history.insertAdjacentHTML('afterend','<section id="history"></section>');
  searchCustomers(history,'customer');

  if(!await result(db.rpc('can_access',{s:shop,p:'customer_edit'}))) return;
  const edit=main.querySelector('#customer-edit');
  const tabs=[main.querySelector('#customer-list-tab'),main.querySelector('#customer-edit-tab')];
  tabs[1].hidden=false;
  const activate=index=>{
    list.hidden=index!==0;
    edit.hidden=index!==1;
    tabs.forEach((tab,i)=>{
      tab.setAttribute('aria-selected',String(i===index));
      tab.tabIndex=i===index?0:-1;
    });
  };
  tabs.forEach((tab,i)=>{
    tab.onclick=()=>activate(i);
    tab.onkeydown=event=>{
      const next={ArrowLeft:1-i,ArrowRight:1-i,Home:0,End:1}[event.key];
      if(next===undefined) return;
      event.preventDefault();
      activate(next);
      tabs[next].focus();
    };
  });
  let selectionVersion=0;
  const picker=form(lookupField('edit_customer','Customer','Type a name or mobile number'),'Edit selected customer',async ({edit_customer:id})=>{
    if(!id) throw new Error('Select a customer.');
    const version=selectionVersion;
    const current=await result(db.from('customers').select(customerColumns).eq('shop_id',shop).eq('id',id).single());
    if(version!==selectionVersion) return;
    editorPanel.replaceChildren();
    const previews=document.createElement('div');
    editorPanel.append(previews);
    const editor=form(customerFields+aadhaarField('New Aadhaar number (leave blank to keep current)')+
      photo('photo','Replace customer photo')+photo('aadhaar_photo','Replace Aadhaar photo'),
      'Save customer changes',async (details,editor)=>{
        for(const [key,category] of [['photo','customer'],['aadhaar_photo','identity']]){
          const file=details[key];
          delete details[key];
          if(file?.size) details[key]=await upload(category,file);
        }
        await result(db.rpc('edit_customer',{s:shop,customer:id,details}));
        editor.elements.aadhaar_number.value='';
        editor.elements.photo.value='';
        editor.elements.aadhaar_photo.value='';
        if(version===selectionVersion){
          picker.querySelector('[role=combobox]').value=details.name.trim();
          previews.replaceChildren();
          await renderPhotos({...current,...details});
          Object.assign(current,details);
        }
        document.querySelector('#message').textContent='Customer updated.';
      },false,editorPanel);
    for(const key of ['name','village','address','mobile','reference']) editor.elements[key].value=current[key]??'';
    function renderPhotos(customer){
      return Promise.all([
        showPhoto(previews,customer.photo,'Current customer photo'),
        showPhoto(previews,customer.aadhaar_photo,'Current Aadhaar photo')
      ]);
    }
    await renderPhotos(current);
  },false,edit);
  const editorPanel=document.createElement('div');
  edit.append(editorPanel);
  picker.elements.edit_customer.onchange=()=>{
    selectionVersion++;
    editorPanel.replaceChildren();
  };
  searchCustomers(picker,'edit_customer');
});
