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
        const description=escape(entry.kind)+' · '+escape(displayDate(entry.paid_on))+' · '+money(entry.amount);
        if(entry.reversed_on){
          history.insertAdjacentHTML('beforeend','<p>'+description+' · Reversed '+escape(displayDate(entry.reversed_on))+
            ' · '+escape(entry.reason)+' · Staff '+escape(entry.staff_email||entry.reversed_by)+'</p>');
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
  await cursorList(document.querySelector('#audit'),cursor=>fetchCursor(
    db.from('pending_releases').select('loan_id,bill,release_date,months,original_months,rate,original_rate,calculated_total,received_amount,principal_write_off,interest_shortfall,short_payment_reason').eq('shop_id',shop),
    [['release_date',false],['loan_id',true]],cursor),(pending,container)=>{
    if(!pending.length) container.textContent='No release overrides awaiting review on this page.';
    for(const r of pending){
      form('<strong>'+escape(r.bill)+'</strong><span>'+escape(displayDate(r.release_date))+'</span>'+
        '<span>Months '+r.original_months+' → '+r.months+'</span><span>Monthly rate '+r.original_rate+'% → '+r.rate+'%</span>'+
        (r.calculated_total!==null&&Number(r.received_amount)<Number(r.calculated_total)?
          '<span>Calculated '+money(r.calculated_total)+' · Received '+money(r.received_amount)+
          ' · Principal shortfall '+money(r.principal_write_off)+
          ' · Interest shortfall '+money(r.interest_shortfall??(r.calculated_total-r.received_amount-r.principal_write_off))+'</span>'+
          (r.short_payment_reason?'<span>Reason '+escape(r.short_payment_reason)+'</span>':''):''),
        'Submit review',(_,editor)=>submitFinancial(editor,'review',{loan:r.loan_id}),true,container);
    }
  });
});
