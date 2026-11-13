import { mount,db,shop,field,option,form,section,result,table } from '../app.js';
import { ledgerCategories } from '../accounting.js';

// Page 1: Ledger & group creation
mount('accounting',async()=>{
  const [groups,ledgers]=await Promise.all([
    result(db.from('ledger_groups').select('id,name,category').eq('shop_id',shop).order('name').order('id')),
    result(db.from('ledgers').select('id,name,ledger_groups(name,category)').eq('shop_id',shop).order('name').order('id')),
  ]);
  form(field('name','Group name','maxlength="100" required')+
    '<label>Account category<select name="category" required>'+option('','Select category')+
    ledgerCategories.map(category=>option(category,category)).join('')+'</select></label>',
    'Create ledger group',data=>result(db.from('ledger_groups').insert({...data,name:data.name.trim(),shop_id:shop})));
  form(field('name','Ledger name','maxlength="100" required')+
    '<label>Ledger group<select name="group_id" required>'+option('','Select group')+
    groups.map(group=>option(group.id,group.name)).join('')+'</select></label>',
    'Create ledger',data=>result(db.from('ledgers').insert({...data,name:data.name.trim(),shop_id:shop})));
  section('<h2>Ledger groups</h2>'+table(['Group','Category'],groups.map(g=>[g.name,g.category])));
  section('<h2>Ledgers</h2>'+table(['Ledger','Group','Category'],
    ledgers.map(l=>[l.name,l.ledger_groups?.name??'',l.ledger_groups?.category??''])));
});
