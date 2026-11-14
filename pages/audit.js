import {displayDate, mount,db,shop,escape,money,field,result,run,form,section,cursorList,fetchCursor,submitFinancial } from '../app.js';

mount('audit', async () => {
  section('<div id="audit"></div>');
  section('<h2>Loan payment corrections</h2><div data-correction-search></div><div data-payment-history></div>');
  const history=document.querySelector('[data-payment-history]');
  form(field('bill','Bill number'),'Find payments',async ({bill})=>{
    history.replaceChildren();
    const loan=await result(db.from('loans').select('id,bill').eq('shop_id',shop).eq('bill',bill.trim()).maybeSingle());
    if(!loan) throw new Error('Bill not found.');
    const load=run(async()=>{
      const entries=await result(db.rpc('loan_payment_history',{s:shop,loan:loan.id}));
      history.replaceChildren();
      if(!entries.length) history.textContent='No payments or top-ups for this bill.';
      for(const entry of entries){
        const description=escape(entry.kind)+' Â· '+escape(displayDate(entry.paid_on))+' Â· '+money(entry.amount);
        if(entry.reversed_on){
          history.insertAdjacentHTML('beforeend','<p>'+description+' Â· Reversed '+escape(displayDate(entry.reversed_on))+
            ' Â· '+escape(entry.reason)+' Â· Staff '+escape(entry.staff_email||entry.reversed_by)+'</p>');
          continue;
        }
        form('<strong>'+description+'</strong>'+field('reason','Reversal reason'),
          'Reverse entry',async ({reason})=>{
            if(!window.confirm('Reverse this entry for bill '+loan.bill+'?')) return;
            await result(db.rpc('reverse_loan_payment',{s:shop,loan:loan.id,entry:entry.id,reason}));
            await load();
          },false,history);
      }
    });
    await load();
  },false,document.querySelector('[data-correction-search]'));
  section('<h2>Release correction history</h2><div data-release-search></div><div data-release-history></div>');
  const releaseHistory=document.querySelector('[data-release-history]');
  form(field('bill','Released bill number','required'),'Find corrections',async ({bill})=>{
    releaseHistory.replaceChildren();
    const loan=await result(db.from('loans').select('id').eq('shop_id',shop).eq('bill',bill.trim()).maybeSingle());
    if(!loan) throw new Error('Bill not found.');
    await cursorList(releaseHistory,cursor=>result(db.rpc('release_correction_history',{
      s:shop,loan:loan.id,before_time:cursor?.edited_at??null,before_id:cursor?.id??null
    })),(entries,container)=>{
      if(!entries.length) container.textContent='No release corrections for this bill.';
      const fields={release_date:'Release date',months:'Months charged',rate:'Monthly rate',total:'Amount received',
        payment_ledger_id:'Bank ledger',full_principal:'Full principal',partial_interest_only:'Partials as interest',
        short_payment_reason:'Short payment reason'};
      const format=(key,value)=>value==null?(key==='payment_ledger_id'?'Cash':'—'):
        key==='total'?money(value):key==='release_date'?displayDate(value):String(value);
      for(const entry of entries){
        const previous=entry.previous_release;
        const corrected=entry.corrected_release;
        const changes=Object.entries(fields).filter(([key])=>previous[key]!==corrected[key]).map(([key,label])=>
          '<li>'+escape(label)+': '+escape(format(key,previous[key]))+' → '+escape(format(key,corrected[key]))+'</li>').join('');
        container.insertAdjacentHTML('beforeend','<p><strong>'+escape(new Date(entry.edited_at).toLocaleString())+
          '</strong> · '+escape(entry.actor)+' · '+escape(entry.reason)+'</p>'+(changes?'<ul>'+changes+'</ul>':''));
      }
    });
  },false,document.querySelector('[data-release-search]'));
  await cursorList(document.querySelector('#audit'),cursor=>fetchCursor(
    db.from('pending_releases').select('loan_id,bill,release_date,months,original_months,rate,original_rate,calculated_total,received_amount,principal_write_off,interest_shortfall,short_payment_reason,correction_pending').eq('shop_id',shop),
    [['release_date',false],['loan_id',true]],cursor),(pending,container)=>{
    if(!pending.length) container.textContent='No release entries awaiting review on this page.';
    for(const r of pending){
      form('<strong>'+escape(r.bill)+'</strong><span>'+escape(displayDate(r.release_date))+'</span>'+
        (r.correction_pending?'<span>Release correction awaiting review</span>':'')+
        '<span>Months '+r.original_months+' â†’ '+r.months+'</span><span>Monthly rate '+r.original_rate+'% â†’ '+r.rate+'%</span>'+
        (r.calculated_total!==null&&Number(r.received_amount)<Number(r.calculated_total)?
          '<span>Calculated '+money(r.calculated_total)+' Â· Received '+money(r.received_amount)+
          ' Â· Principal shortfall '+money(r.principal_write_off)+
          ' Â· Interest shortfall '+money(r.interest_shortfall??(r.calculated_total-r.received_amount-r.principal_write_off))+'</span>'+
          (r.short_payment_reason?'<span>Reason '+escape(r.short_payment_reason)+'</span>':''):''),
        'Submit review',(_,editor)=>submitFinancial(editor,'review',{loan:r.loan_id}),true,container);
    }
  });
});
