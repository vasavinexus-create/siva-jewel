import { mount,db,shop,escape,field,money,today,result,run,form,section,customerPreview,customerPreviewFields,lookupField,searchLookup,submitFinancial } from '../app.js';

mount('release', async () => {
  let version=0;
  let timer;
  let ready=false;
  const editor=form(lookupField('loan','Bill','Type a bill number, customer name or mobile')+
    field('on_date','Release date','type="date" required value="'+today()+'"')+
    field('billed_months','Months charged','type="number" min="0" step="1" required')+
    field('monthly_rate','Monthly interest %','type="number" min="0" max="9999.9999" step=".0001" required'),'Record release',async (data,editor)=>{
    if(!ready) throw new Error('Wait for the current quote.');
    await submitFinancial(editor,'release',data);
  });
  const preview=customerPreview(editor);
  section('<div id="quote"></div>');
  const e=editor.elements;
  const target=document.querySelector('#quote');
  const button=editor.querySelector('button[type=submit]');
  const lock=()=>{
    ready=false;
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
    if(!defaults&&(!e.billed_months.value||!e.monthly_rate.value||!editor.checkValidity())) return;
    const q=await result(db.rpc('release_quote',{
      loan:e.loan.value,on_date:e.on_date.value,
      billed_months:defaults?null:Number(e.billed_months.value),monthly_rate:defaults?null:Number(e.monthly_rate.value)
    }));
    if(ticket!==version) return;
    e.on_date.min=q.loan_date;
    if(defaults){e.billed_months.value=q.months;e.monthly_rate.value=q.rate;}
    target.innerHTML='<h2>'+escape(q.bill)+'</h2><p>'+escape(q.loan_date)+' · '+escape(q.grams)+' g · '+escape(q.notes)+'</p>'+
      '<div class="metrics"><span>Principal '+money(q.amount)+'</span><span>Total interest '+money(q.gross_interest)+
      '</span><span>Interest paid in advance '+money(q.advance_interest)+'</span><span>Interest due '+money(q.interest)+
      '</span><strong>Total due '+money(q.total)+'</strong></div>';
    ready=true;
    button.disabled=false;
  };
  const load=run(async()=>{
    const ticket=lock();
    target.textContent='';
    await quote(ticket,true);
  });
  e.loan.onchange=()=>{
    const id=e.loan.value;
    void preview(id?async()=>{
      const row=await result(db.from('loans').select('photo,customers('+customerPreviewFields+')')
        .eq('shop_id',shop).eq('id',id).single());
      return {customer:row.customers,jewel:row.photo};
    }:null);
    void load();
  };
  e.on_date.onchange=load;
  e.billed_months.oninput=e.monthly_rate.oninput=()=>{
    const ticket=lock();
    target.textContent='Updating quote…';
    timer=setTimeout(run(()=>quote(ticket,false)),200);
  };
  searchLookup(editor,'loan',term=>result(db.rpc('search_open_loans',{s:shop,term})),
    l=>l.bill+' · '+l.customer);
  await load();
});
