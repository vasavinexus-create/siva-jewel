import { mount,db,shop,escape,field,money,today,result,run,form,section,showPhoto,searchInput,submitFinancial } from '../app.js';

mount('release', async () => {
  let version=0;
  let timer;
  let ready=false;
  const editor=form(field('search','Bill, customer name or mobile','type="search"')+'<label>Bill<select name="loan" required></select></label>'+
    field('on_date','Release date','type="date" required value="'+today()+'"')+
    field('billed_months','Months charged','type="number" min="0" step="1" required')+
    field('monthly_rate','Monthly interest %','type="number" min="0" max="9999.9999" step=".0001" required'),'Record release',async (data,editor)=>{
    if(!ready) throw new Error('Wait for the current quote.');
    delete data.search;
    await submitFinancial(editor,'release',data);
  });
  section('<div id="quote"></div><div id="jewel"></div>');
  const e=editor.elements;
  const target=document.querySelector('#quote');
  const jewel=document.querySelector('#jewel');
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
      '<div class="metrics"><span>Loan '+money(q.amount)+'</span><span>Interest '+money(q.interest)+'</span><strong>Total '+money(q.total)+'</strong></div>';
    ready=true;
    button.disabled=false;
    if(defaults) await showPhoto(jewel,q.photo,'Pledged jewel');
  };
  const load=run(async()=>{
    const ticket=lock();
    target.textContent='';
    jewel.replaceChildren();
    await quote(ticket,true);
  });
  e.loan.onchange=load;
  e.on_date.onchange=load;
  e.billed_months.oninput=e.monthly_rate.oninput=()=>{
    const ticket=lock();
    target.textContent='Updating quote…';
    timer=setTimeout(run(()=>quote(ticket,false)),200);
  };
  await searchInput(e.search,e.loan,term=>result(db.rpc('search_open_loans',{s:shop,term})),
    l=>l.bill+' · '+l.customer,'Select bill',load);
});
