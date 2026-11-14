import { db,shop,option,fetchCursor } from './app.js';

export const accounts = ['Cash','Other assets','Liabilities','Capital','Other income','Expenses'];
export const ledgerCategories = ['Bank',...accounts.slice(1)];

export const paymentFields = '<label>Payment mode<select name="payment_mode"><option value="cash">Cash</option>'+
  '<option value="bank">Bank</option></select></label><label hidden>Bank ledger<select name="payment_ledger_id" disabled></select></label>';

export async function loadLedgerOptions(query) {
  const batchSize=250;
  const rows=[];
  const columns=[['name',true],['id',true]];
  let cursor=null;
  while(true){
    const page=await fetchCursor(query(),columns,cursor,batchSize);
    rows.push(...page.slice(0,batchSize));
    if(page.length<=batchSize) return rows;
    cursor=rows.at(-1);
  }
}

export async function loadBankLedgers(editor) {
  const mode=editor.elements.payment_mode;
  const bank=editor.elements.payment_ledger_id;
  const sync=()=>{
    const useBank=mode.value==='bank';
    bank.closest('label').hidden=!useBank;
    bank.disabled=!useBank;
    bank.required=useBank;
    if(!useBank) bank.value='';
  };
  mode.onchange=sync;
  sync();
  bank.innerHTML=option('','Loading bank ledgersâ€¦');
  const ledgers=await loadLedgerOptions(()=>db.from('ledgers').select('id,name,ledger_groups!inner(category)')
    .eq('shop_id',shop).eq('ledger_groups.category','Bank'));
  bank.innerHTML=option('',ledgers.length?'Select bank ledger':'Create a bank ledger in Accounting')+
    ledgers.map(ledger=>option(ledger.id,ledger.name)).join('');
}
