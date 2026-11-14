import { db, shop, result, run, form, field, dateField, lookupField, searchLookup, searchCustomers, photo, showPhoto, upload, escape, money } from '../app.js';
import { paymentFields, loadBankLedgers } from '../accounting.js';

export async function setupPledgeEdit(panel) {
  panel.innerHTML='<form data-bill-picker>'+lookupField('edit_loan','Bill number','Type a bill number')+
    '<button type="submit" disabled>Open bill</button></form><div data-bill-details></div>';
  const picker=panel.querySelector('[data-bill-picker]');
  const selected=picker.querySelector('[name=edit_loan]');
  const open=picker.querySelector('button');
  const details=panel.querySelector('[data-bill-details]');
  selected.onchange=()=>{
    open.disabled=!selected.value;
    details.replaceChildren();
  };
  searchLookup(picker,'edit_loan',term=>result(db.rpc('search_pledge_edits',{s:shop,term})),
    loan=>loan.bill+' · '+loan.customer);

  const [canEditAll,canEditDetails]=await Promise.all(['pledge_edit_all','pledge_edit_details'].map(
    p=>result(db.rpc('can_access',{s:shop,p}))
  ));
  open.textContent=canEditAll||canEditDetails?'Edit bill':'View bill';
  picker.onsubmit=run(async event=>{
    event.preventDefault();
    await loadBill();
  });
  async function loadBill() {
    const id=selected.value;
    const loan=await result(db.from('loans').select('*,customer:customers(name)').eq('shop_id',shop).eq('id',id).single());
    if(selected.value!==id) return;
    details.innerHTML='<h2>Bill '+escape(loan.bill)+'</h2><p>Customer '+escape(loan.customer.name)+
      ' · Pledged '+escape(loan.loan_date)+' · Principal '+money(loan.amount)+' · Monthly interest '+escape(loan.rate)+
      '% · Advance interest '+money(loan.advance_interest)+' · '+escape(loan.grams)+' g</p><p>'+escape(loan.notes)+'</p>';
    const image=document.createElement('div');
    details.append(image);
    if(!canEditAll&&!canEditDetails) {
      await showPhoto(image,loan.photo,'Current jewel photo');
      return;
    }

    const financial=canEditAll?dateField('loan_date','Pledge date',loan.loan_date)+
      field('amount','Loan principal (INR)','type="number" min=".01" step=".01" required')+
      field('rate','Monthly interest %','type="number" min="0" step=".0001" required')+
      field('advance_interest','Advance interest collected (INR)','type="number" min="0" step=".01" required')+paymentFields:'';
    let uploadedFile;
    let uploadedPath;
    const editor=form(field('bill','Bill number')+lookupField('edit_customer','Customer','Type a name or mobile number')+
      field('grams','Grams','type="number" min=".001" step=".001" required')+field('notes','Jewel details and notes','')+
      photo('replacement','Replace jewel photo')+
      (loan.photo?'<label><span><input type="checkbox" name="remove_photo"> Remove current jewel photo</span></label>':'')+
      financial,'Save bill changes',async(data,editor)=>{
        if(!data.edit_customer) throw new Error('Select a customer.');
        const {bill,grams,notes}=data;
        const changes={bill,grams,notes,customer_id:data.edit_customer};
        if(canEditAll) Object.assign(changes,{
          amount:data.amount,rate:data.rate,loan_date:data.loan_date,advance_interest:data.advance_interest,
          payment_ledger_id:data.payment_mode==='bank'?data.payment_ledger_id:null
        });
        const file=editor.elements.replacement.files[0];
        if(file&&data.remove_photo) throw new Error('Choose either to replace or remove the photo.');
        if(file&&file!==uploadedFile){
          uploadedPath=await upload('jewel',file);
          uploadedFile=file;
        }
        if(file||data.remove_photo) changes.photo=file?uploadedPath:null;
        await result(db.rpc('edit_pledge',{s:shop,loan:id,changes}));
        await loadBill();
        document.querySelector('#message').textContent='Bill updated.';
      },false,details);
    for(const name of ['bill','grams','notes','amount','rate','advance_interest']){
      if(editor.elements[name]) editor.elements[name].value=loan[name]??'';
    }
    editor.elements.edit_customer.value=loan.customer_id;
    editor.querySelector('#edit_customer-search').value=loan.customer.name;
    searchCustomers(editor,'edit_customer');
    if(canEditAll){
      const save=editor.querySelector('[type=submit]');
      save.disabled=true;
      const loading=loadBankLedgers(editor);
      editor.elements.payment_mode.value=loan.payment_ledger_id?'bank':'cash';
      editor.elements.payment_mode.onchange();
      await loading;
      editor.elements.payment_ledger_id.value=loan.payment_ledger_id??'';
      save.disabled=false;
    }
    await showPhoto(image,loan.photo,'Current jewel photo');
  }
}
