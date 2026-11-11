import { mount,db,shop,escape,form,section,cursorList,fetchCursor,submitFinancial } from '../app.js';

mount('audit', async () => {
  section('<div id="audit"></div>');
  await cursorList(document.querySelector('#audit'),cursor=>fetchCursor(
    db.from('pending_releases').select('loan_id,bill,release_date,months,original_months,rate,original_rate').eq('shop_id',shop),
    [['release_date',false],['loan_id',true]],cursor),(pending,container)=>{
    if(!pending.length) container.textContent='No release overrides awaiting review on this page.';
    for(const r of pending){
      form('<strong>'+escape(r.bill)+'</strong><span>'+escape(r.release_date)+'</span>'+
        '<span>Months '+r.original_months+' → '+r.months+'</span><span>Monthly rate '+r.original_rate+'% → '+r.rate+'%</span>',
        'Submit review',(_,editor)=>submitFinancial(editor,'review',{loan:r.loan_id}),true,container);
    }
  });
});
