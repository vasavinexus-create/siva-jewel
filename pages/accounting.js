import { mount,db,shop,field,option,money,today,result,form,section,paginated } from '../app.js';
import { accounts } from '../accounting.js';

mount('accounting',async()=>{
    const options=option('','Select account')+accounts.map(a=>option(a,a)).join('');
    form(field('entry_date','Posting date','type="date" required value="'+today()+'"')+
      field('description','Description')+'<label>Debit<select name="debit" required>'+options+'</select></label>'+
      '<label>Credit<select name="credit" required>'+options+'</select></label>'+
      field('amount','Amount (INR)','type="number" min=".01" step=".01" required'),
      'Post journal entry',data=>result(db.from('journal').insert({...data,shop_id:shop})));
    section('<div id="journal"></div>');
    await paginated(document.querySelector('#journal'),['Date','Description','Debit','Credit','Amount'],
      (from,to)=>result(db.from('journal').select('entry_date,description,debit,credit,amount')
        .eq('shop_id',shop).order('entry_date',{ascending:false}).order('id').range(from,to)),
      j=>[j.entry_date,j.description,j.debit,j.credit,money(j.amount)]);
});
