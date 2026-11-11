import { mount,db,shop,field,option,money,today,form,section,paginated,fetchCursor,submitFinancial } from '../app.js';
import { accounts } from '../accounting.js';

mount('accounting',async()=>{
    const options=option('','Select account')+accounts.map(a=>option(a,a)).join('');
    form(field('entry_date','Posting date','type="date" required value="'+today()+'"')+
      field('description','Description')+'<label>Debit<select name="debit" required>'+options+'</select></label>'+
      '<label>Credit<select name="credit" required>'+options+'</select></label>'+
      field('amount','Amount (INR)','type="number" min=".01" step=".01" required'),
      'Post journal entry',(data,editor)=>submitFinancial(editor,'journal',data));
    section('<div id="journal"></div>');
    await paginated(document.querySelector('#journal'),['Date','Description','Debit','Credit','Amount'],
      cursor=>fetchCursor(db.from('journal').select('id,entry_date,description,debit,credit,amount')
        .eq('shop_id',shop),[['entry_date',false],['id',true]],cursor),
      j=>[j.entry_date,j.description,j.debit,j.credit,money(j.amount)]);
});
