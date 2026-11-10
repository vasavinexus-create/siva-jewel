import { mount,db,shop,escape,form,result,section,pageOffset,pageLinks } from '../app.js';

mount('audit', async () => {
  const offset=pageOffset();
  const pending=await result(db.from('pending_releases').select('loan_id,bill,release_date,months,original_months,rate,original_rate')
    .eq('shop_id',shop).order('release_date',{ascending:false}).order('loan_id').range(offset,offset+50));
  if(!pending.length) section('No release overrides awaiting review on this page.');
  for(const r of pending.slice(0,50)){
    form('<strong>'+escape(r.bill)+'</strong><span>'+escape(r.release_date)+'</span>'+
      '<span>Months '+r.original_months+' → '+r.months+'</span><span>Monthly rate '+r.original_rate+'% → '+r.rate+'%</span>',
      'Submit review',()=>result(db.rpc('review_release',{loan:r.loan_id})));
  }
  pageLinks(offset,pending.length>50);
});
