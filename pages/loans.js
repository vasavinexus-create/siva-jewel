import { mount,db,shop,result,money,run,customerPreview,customerPreviewFields,field,photo,today,form,upload,lookupField,searchCustomers,submitFinancial } from '../app.js';
import { paymentFields,loadBankLedgers } from '../accounting.js';

mount('loans',async()=>{
    let uploadedFile;
    let photoPath;
    let quoted=false;
    let quoteVersion=0;
    let timer;
    const editor=form(lookupField('customer_id','Customer','Type a name or mobile number')+
      field('bill','Bill number')+field('loan_date','Pledge date','type="date" required value="'+today()+'"')+
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
      });
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
    await loadBankLedgers(editor);
});
