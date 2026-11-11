import { mount,db,shop,escape,field,option,money,today,table,result,form,paginated,fetchCursor } from '../app.js';

const kinds=['Day book','Pledging','Releases','Profit and loss','Balance sheet','Trial balance','General ledger','Loan balance'];
const summaries=new Set(['Profit and loss','Balance sheet','Trial balance','Loan balance']);

mount('reports', async () => {
  const filters=form('<label>Report<select name="kind">'+kinds.map(v=>option(v,v)).join('')+'</select></label>'+
    field('from','From','type="date"')+field('to','Through','type="date" value="'+today()+'"'),'Run report',async ({kind,from,to})=>{
    if(from&&to&&from>to) throw new Error('The start date must be on or before the end date.');
    const report=document.querySelector('#report');
    report.innerHTML='<h2>'+escape(kind)+'</h2><div data-result></div>';
    const output=report.querySelector('[data-result]');
    const dates=(query,column)=>{
      if(from) query.gte(column,from);
      if(to) query.lte(column,to);
      return query;
    };
    let summary;
    if(summaries.has(kind)){
      summary=await result(db.rpc('report_summary',{s:shop,kind,from_date:from||null,to_date:to||null}));
      if(kind!=='Loan balance'){
        const headers=kind==='Trial balance'?['Account','Debit balance','Credit balance']:['Account','Amount'];
        output.innerHTML=table(headers,summary.map(([label,...amounts])=>[label,...amounts.map(money)]));
        return;
      }
    }
    if(kind==='Loan balance'){
      output.insertAdjacentHTML('beforebegin','<p>Outstanding principal '+money(summary.principal)+'</p>');
      await paginated(output,['Bill','Date','Principal'],
        cursor=>fetchCursor(db.rpc('outstanding_loans',{s:shop,to_date:to||null}),[['loan_date',true],['id',true]],cursor),
        l=>[l.bill,l.loan_date,money(l.amount)]);
    } else if(kind==='Pledging'){
      await paginated(output,['Date','Bill','Cash out'],
        cursor=>fetchCursor(dates(db.from('loans').select('id,loan_date,bill,amount').eq('shop_id',shop),'loan_date'),
          [['loan_date',true],['id',true]],cursor),
        l=>[l.loan_date,l.bill,money(l.amount)]);
    } else if(kind==='Releases'){
      await paginated(output,['Date','Bill','Cash in','Interest'],
        cursor=>fetchCursor(dates(db.from('releases').select('loan_id,release_date,total,interest,loans(bill)').eq('shop_id',shop),'release_date'),
          [['release_date',true],['loan_id',true]],cursor),
        r=>[r.release_date,r.loans?.bill,money(r.total),money(r.interest)]);
    } else {
      await paginated(output,['Date','Entry','Debit','Credit','Amount'],
        cursor=>fetchCursor(dates(db.from('ledger_entries').select('id,line,entry_date,description,debit,credit,amount').eq('shop_id',shop),'entry_date'),
          [['entry_date',true],['id',true],['line',true]],cursor),
        e=>[e.entry_date,e.description,e.debit,e.credit,money(e.amount)]);
    }
  },false);
  filters.insertAdjacentHTML('afterend','<section id="report"></section>');
});
