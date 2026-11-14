import { dateField, mount,db,shop,field,option,money,today,form,section,paginated,fetchCursor,submitFinancial,result } from '../app.js';
import { accounts,loadLedgerOptions } from '../accounting.js';

// Page 2: Post journal entry + recent journal entries
mount('journal',async()=>{
  const ledgers=await loadLedgerOptions(()=>db.from('ledgers').select('id,name,ledger_groups(name)').eq('shop_id',shop));
  const options=option('','Select account')+accounts.map(account=>option(account,account)).join('')+
    ledgers.map(ledger=>option(ledger.id,ledger.name+' Â· '+ledger.ledger_groups?.name)).join('');
  form(dateField('entry_date','Posting date')+
    field('description','Description')+'<label>Debit<select name="debit" required>'+options+'</select></label>'+
    '<label>Credit<select name="credit" required>'+options+'</select></label>'+
    field('amount','Amount (INR)','type="number" min=".01" step=".01" required'),
    'Post journal entry',({debit,credit,...data},editor)=>submitFinancial(editor,'journal',{
      ...data,
      ...(accounts.includes(debit)?{debit}:{debit_ledger_id:debit}),
      ...(accounts.includes(credit)?{credit}:{credit_ledger_id:credit}),
    }));
  section('<h2>Recent journal entries</h2><div id="journal"></div>');
  const byId=new Map(ledgers.map(ledger=>[ledger.id,ledger.name]));
  await paginated(document.querySelector('#journal'),['Date','Description','Debit','Credit','Amount'],
    cursor=>fetchCursor(db.from('journal').select('id,entry_date,description,debit,credit,amount,debit_ledger_id,credit_ledger_id')
      .eq('shop_id',shop),[['entry_date',false],['id',true]],cursor),
    j=>[j.entry_date,j.description,byId.get(j.debit_ledger_id)??j.debit,byId.get(j.credit_ledger_id)??j.credit,money(j.amount)]);
});
