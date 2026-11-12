import { mount,db,shop,field,option,money,today,form,section,paginated,fetchCursor,submitFinancial,result,table } from '../app.js';
import { accounts,ledgerCategories } from '../accounting.js';

mount('accounting',async()=>{
  const [groups,ledgers,balances]=await Promise.all([
    result(db.from('ledger_groups').select('id,name').eq('shop_id',shop).order('name').order('id')),
    result(db.from('ledgers').select('id,name,ledger_groups(name)').eq('shop_id',shop).order('name').order('id')),
    result(db.rpc('ledger_balances',{s:shop}).order('group_name').order('name')),
  ]);
  form(field('name','Group name','maxlength="100" required')+
    '<label>Account category<select name="category" required>'+option('','Select category')+
    ledgerCategories.map(category=>option(category,category)).join('')+'</select></label>',
    'Create ledger group',data=>result(db.from('ledger_groups').insert({...data,name:data.name.trim(),shop_id:shop})));
  form(field('name','Ledger name','maxlength="100" required')+
    '<label>Ledger group<select name="group_id" required>'+option('','Select group')+
    groups.map(group=>option(group.id,group.name)).join('')+'</select></label>',
    'Create ledger',data=>result(db.from('ledgers').insert({...data,name:data.name.trim(),shop_id:shop})));
  section('<h2>Ledger balances</h2>'+table(['Ledger','Group','Balance (debit less credit)'],
    balances.map(row=>[row.name,row.group_name,money(row.balance)])));

  const options=option('','Select account')+accounts.map(account=>option(account,account)).join('')+
    ledgers.map(ledger=>option(ledger.id,ledger.name+' · '+ledger.ledger_groups?.name)).join('');
  form(field('entry_date','Posting date','type="date" required value="'+today()+'"')+
    field('description','Description')+'<label>Debit<select name="debit" required>'+options+'</select></label>'+
    '<label>Credit<select name="credit" required>'+options+'</select></label>'+
    field('amount','Amount (INR)','type="number" min=".01" step=".01" required'),
    'Post journal entry',({debit,credit,...data},editor)=>submitFinancial(editor,'journal',{
      ...data,
      ...(accounts.includes(debit)?{debit}:{debit_ledger_id:debit}),
      ...(accounts.includes(credit)?{credit}:{credit_ledger_id:credit}),
    }));
  section('<h2>Journal entries</h2><div id="journal"></div>');
  const byId=new Map(ledgers.map(ledger=>[ledger.id,ledger.name]));
  await paginated(document.querySelector('#journal'),['Date','Description','Debit','Credit','Amount'],
    cursor=>fetchCursor(db.from('journal').select('id,entry_date,description,debit,credit,amount,debit_ledger_id,credit_ledger_id')
      .eq('shop_id',shop),[['entry_date',false],['id',true]],cursor),
    j=>[j.entry_date,j.description,byId.get(j.debit_ledger_id)??j.debit,byId.get(j.credit_ledger_id)??j.credit,money(j.amount)]);
});
