import { displayDate,dateField, mount,db,shop,escape,field,money,today,result,run,form,table,customerPreview,customerPreviewFields,lookupField,searchLookup,submitFinancial } from '../app.js';
import { paymentFields,loadBankLedgers } from '../accounting.js';

import { mountPartialPayment } from './partial-payment.js';

mount('release', async () => {
  const main=document.querySelector('main');
  main.insertAdjacentHTML('beforeend',`
    <div class="owner-tabs" role="tablist" aria-label="Release">
      <button type="button" role="tab" id="release-tab" aria-controls="release-panel">Release</button>
      <button type="button" role="tab" id="partial-payment-tab" aria-controls="partial-payment-panel">Partial Payment</button>
    </div>
    <div id="release-panel" role="tabpanel" aria-labelledby="release-tab"></div>
    <div id="partial-payment-panel" role="tabpanel" aria-labelledby="partial-payment-tab" hidden></div>`);
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
      const next={ArrowLeft:1-i,ArrowRight:1-i,Home:0,End:1}[event.key];
      if(next===undefined) return;
      event.preventDefault();
      activate(next);
      tabs[next].focus();
    };
  });
  activate(0);
  let version=0;
  let timer;
  let currentQuote;
  let receivedEdited=false;
  const editor=form(lookupField('loan','Bill','Type a bill number, customer name or mobile')+
    dateField('on_date','Release date')+
    field('billed_months','Months charged','type="number" min="0" step="1" required')+
    field('monthly_rate','Monthly interest %','type="number" min="0" max="9999.9999" step=".0001" required')+
    '<label><input type="checkbox" name="full_principal"> Charge interest on the full principal from the pledge date</label>'+
    '<label><input type="checkbox" name="partial_interest_only"> Treat all partial payments as advance interest</label>'+
    field('received_amount','Received amount (INR)','type="number" min="0" step=".01" required')+
    '<div data-settlement aria-live="polite"></div>'+
    '<label hidden data-short-reason>Reason for short payment<textarea name="short_payment_reason" disabled></textarea></label>'+
    paymentFields,'Record release',async (data,editor)=>{
    if(!currentQuote) throw new Error('Wait for the current quote.');
    if(!window.confirm('Release '+editor.querySelector('[role=combobox]').value+'?\n'+
      'Jewel '+currentQuote.grams+' g'+(currentQuote.notes?' · '+currentQuote.notes:'')+'\nReceived '+money(data.received_amount))) return;
    try {
      await submitFinancial(editor,'release',{...data,full_principal:e.full_principal.checked,partial_interest_only:e.partial_interest_only.checked,expected_quote:currentQuote});
    } catch(error) {
      if(error.message.includes('release quote changed')){
        receivedEdited=true;
        await load();
        throw new Error('The release quote changed. Review the updated total and confirm the amount received.');
      }
      throw error;
    }
    location.reload();
  },false,panels[0]);
  const preview=customerPreview(editor);
  panels[0].insertAdjacentHTML('beforeend','<section><div id="quote"></div></section>');
  const e=editor.elements;
  const target=document.querySelector('#quote');
  const button=editor.querySelector('button[type=submit]');
  const settlement=editor.querySelector('[data-settlement]');
  const reason=editor.querySelector('[data-short-reason]');
  const showDifference=()=>{
    settlement.textContent='';
    reason.hidden=e.short_payment_reason.disabled=true;
    e.short_payment_reason.required=false;
    if(!currentQuote||e.received_amount.value===''||!e.received_amount.validity.valid) return;
    const difference=Math.round(Number(e.received_amount.value)*100)-Math.round(currentQuote.total*100);
    if(difference<0) {
      const principalShort=Math.max(0,Math.round(currentQuote.amount*100)-Math.round(Number(e.received_amount.value)*100));
      settlement.textContent='Principal shortfall '+money(principalShort/100)+' · Interest shortfall '+money((-difference-principalShort)/100)+' · Sent to Audit';
      reason.hidden=e.short_payment_reason.disabled=false;
      e.short_payment_reason.required=true;
    }
    if(difference>0) settlement.textContent='Extra received as interest '+money(difference/100);
  };
  e.received_amount.oninput=()=>{
    receivedEdited=e.received_amount.value!=='';
    showDifference();
  };
  const lock=()=>{
    currentQuote=null;
    showDifference();
    button.disabled=true;
    clearTimeout(timer);
    return ++version;
  };
  const quote=async (ticket,defaults)=>{
    if(!e.loan.value||!e.on_date.value){
      e.on_date.removeAttribute('min');
      target.textContent='Select an open bill and a release date.';
      return;
    }
    if(!defaults&&(!e.billed_months.value||!e.monthly_rate.value||!e.billed_months.validity.valid||!e.monthly_rate.validity.valid)) return;
    const q=await result(db.rpc('release_quote',{
      loan:e.loan.value,on_date:e.on_date.value,
      billed_months:defaults?null:Number(e.billed_months.value),monthly_rate:defaults?null:Number(e.monthly_rate.value),
      full_principal:e.full_principal.checked,partial_interest_only:e.partial_interest_only.checked
    }));
    if(ticket!==version) return;
    e.on_date.min=q.loan_date;
    if(defaults){e.billed_months.value=q.months;e.monthly_rate.value=q.rate;}
    target.innerHTML='<h2>'+escape(q.bill)+'</h2><p>'+escape(displayDate(q.loan_date))+' · '+escape(q.grams)+' g · '+escape(q.notes)+'</p>'+
      '<div class="metrics"><span>Principal '+money(q.amount)+'</span><span>Total interest '+money(q.gross_interest)+
      '</span><span>Interest paid in advance '+money(q.advance_interest)+'</span><span>Interest due '+money(q.interest)+
      '</span>'+ (q.advance_to_principal>0?'<span>Advance applied to principal '+money(q.advance_to_principal)+'</span>':'')+
      (q.excess_advance>0?'<span>Excess advance kept as interest '+money(q.excess_advance)+'</span>':'')+
      '<strong>Calculated amount '+money(q.total)+'</strong></div>'+
      '<h3>Interest breakdown</h3>'+table(['From','Principal','Months','Interest per month','Total interest'],
        q.breakdown.map(row=>[row.date,money(row.amount),row.months,money(row.monthly_interest),money(row.interest)]));
    currentQuote=q;
    if(!receivedEdited) e.received_amount.value=q.total;
    showDifference();
    button.disabled=false;
  };
  const load=run(async()=>{
    const ticket=lock();
    target.textContent='';
    await quote(ticket,true);
  });
  e.loan.onchange=()=>{
    e.partial_interest_only.checked=false;
    receivedEdited=false;
    e.received_amount.value='';
    const id=e.loan.value;
    void preview(id?async()=>{
      const row=await result(db.from('loans').select('photo,customers('+customerPreviewFields+')')
        .eq('shop_id',shop).eq('id',id).single());
      return {customer:row.customers,jewel:row.photo};
    }:null);
    void load();
  };
  e.on_date.onchange=load;
  e.partial_interest_only.onchange=e.full_principal.onchange=e.billed_months.oninput=e.monthly_rate.oninput=()=>{
    const ticket=lock();
    target.textContent='Updating quoteâ€¦';
    timer=setTimeout(run(()=>quote(ticket,false)),200);
  };
  searchLookup(editor,'loan',term=>result(db.rpc('search_open_loans',{s:shop,term})),
    l=>l.bill+' · '+l.customer);
  await Promise.all([load(),loadBankLedgers(editor),mountPartialPayment(panels[1])]);
});
