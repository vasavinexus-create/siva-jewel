import { mount,db,shop,money,section,result,table } from '../app.js';

// Page 3: Ledger balances
mount('balances',async()=>{
  const balances=await result(db.rpc('ledger_balances',{s:shop}).order('group_name').order('name'));
  section('<h2>Ledger balances</h2>'+table(['Ledger','Group','Balance (debit less credit)'],
    balances.map(row=>[row.name,row.group_name,money(row.balance)])));
});
