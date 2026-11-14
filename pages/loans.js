import { dateField, mount,db,shop,result,money,run,customerPreview,customerPreviewFields,loanPreview,field,photo,today,form,upload,lookupField,searchCustomers,searchLookup,submitFinancial } from '../app.js';
import { paymentFields,loadBankLedgers } from '../accounting.js';
import { setupPledgeEdit } from './pledge-edit.js';

mount('loans',async()=>{
    const main=document.querySelector('main');
    main.insertAdjacentHTML('beforeend',`
      <div class="owner-tabs" role="tablist" aria-label="Pledge loan">
        <button type="button" role="tab" id="pledge-tab" aria-controls="pledge-panel">New pledge</button>
        <button type="button" role="tab" id="top-up-tab" aria-controls="top-up-panel">Add loan amount</button>
        <button type="button" role="tab" id="edit-tab" aria-controls="edit-panel">Edit</button>
      </div>
      <div id="pledge-panel" role="tabpanel" aria-labelledby="pledge-tab"></div>
      <div id="top-up-panel" role="tabpanel" aria-labelledby="top-up-tab" hidden></div>
      <div id="edit-panel" role="tabpanel" aria-labelledby="edit-tab" hidden></div>`);
    const tabs=[...main.querySelectorAll('[role=tab]')];
    const panels=tabs.map(tab=>document.getElementById(tab.getAttribute('aria-controls')));
    const activate=index=>{
      tabs.forEach((tab,i)=>{
        tab.setAttribute('aria-selected',String(i===index));
        tab.tabIndex=i===index?0:-1;
        panels[i].hidden=i!==index;
      });
    };
    tabs.forEach((tab,i)=>{
      tab.onclick=()=>activate(i);
      tab.onkeydown=event=>{
        const next={ArrowLeft:(i+tabs.length-1)%tabs.length,ArrowRight:(i+1)%tabs.length,Home:0,End:tabs.length-1}[event.key];
        if(next===undefined) return;
        event.preventDefault();
        activate(next);
        tabs[next].focus();
      };
    });
    activate(0);

    const topUp=form(lookupField('loan','Bill number','Type an open bill number')+
      dateField('paid_on','Payment date')+
      field('amount','Additional amount paid (INR)','type="number" min=".01" step=".01" required')+
      paymentFields,'Save additional payment',async (data,editor)=>{
        if(!data.loan) throw new Error('Select an open bill.');
        if(!window.confirm('Add '+money(data.amount)+' to '+editor.querySelector('[role=combobox]').value+'?'+
          (data.paid_on<today()?'\nThis backdated top-up changes the bill balance and interest from the entered date.':''))) return;
        await submitFinancial(editor,'top_up',data);
        location.reload();
      },false,panels[1]);
    const previewTopUp=loanPreview(topUp);
    topUp.elements.loan.onchange=()=>previewTopUp(topUp.elements.loan.value);
    searchLookup(topUp,'loan',term=>result(db.rpc('search_top_up_bills',{s:shop,term})),
      loan=>loan.bill+' · '+loan.customer);

    let uploadedFile;
    let photoPath;
    let quoted=false;
    let quoteVersion=0;
    let timer;
    const editor=form(lookupField('customer_id','Customer','Type a name or mobile number')+
      field('bill','Bill number')+dateField('loan_date','Pledge date')+
      field('amount','Loan principal (INR)','type="number" min=".01" step=".01" required')+
      field('grams','Grams','type="number" min=".001" step=".001" required')+
      field('rate','Monthly interest %','type="number" min="0" max="99.9999" step=".0001" required')+
      field('notes','Jewel details and notes','')+photo('photo','Jewel photo')+paymentFields,'Save pledge',async (data,editor)=>{
        if(!quoted) throw new Error('Wait for the disbursement calculation.');
        const file=editor.elements.photo.files[0];
        if(file!==uploadedFile){
          photoPath=await upload('jewel',file);
          uploadedFile=file;
        }
        data.photo=photoPath??null;
        await submitFinancial(editor,'pledge',{...data,collect_advance:true});
      },true,panels[0]);
    const save=editor.querySelector('button[type=submit]');
    save.insertAdjacentHTML('beforebegin','<div class="metrics" aria-live="polite" data-disbursement></div>');
    const output=editor.querySelector('[data-disbursement]');
    const {amount,rate}=editor.elements;
    const refreshQuote=()=>{
      const ticket=++quoteVersion;
      clearTimeout(timer);
      quoted=false;
      output.textContent='Enter the principal and monthly rate to calculate cash paid.';
      if(!amount.value||!rate.value||!amount.validity.valid||!rate.validity.valid) return;
      output.textContent='Calculating cash paid…';
      timer=setTimeout(run(async()=>{
        const quote=await result(db.rpc('pledge_quote',{s:shop,principal:amount.value,monthly_rate:rate.value}));
        if(ticket!==quoteVersion) return;
        output.innerHTML='<span>Principal '+money(quote.principal)+'</span><span>First-month interest '+money(quote.advance_interest)+
          '</span><strong>Cash paid '+money(quote.net_paid)+'</strong>';
        quoted=true;
      }),200);
    };
    amount.oninput=rate.oninput=refreshQuote;
    refreshQuote();
    const preview=customerPreview(editor);
    const customer=editor.elements.customer_id;
    customer.onchange=()=>{
      const id=customer.value;
      return preview(id?async()=>({
        customer:await result(db.from('customers').select(customerPreviewFields).eq('shop_id',shop).eq('id',id).single())
      }):null);
    };
    searchCustomers(editor,'customer_id');
    await Promise.all([loadBankLedgers(editor),loadBankLedgers(topUp),setupPledgeEdit(panels[2])]);
});
