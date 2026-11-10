import { mount,db,shop,field,photo,today,result,form,upload,searchCustomers } from '../app.js';

mount('loans',async()=>{
    const editor=form(field('search','Search name or mobile','type="search"')+'<label>Customer<select name="customer_id" required></select></label>'+
      field('bill','Bill number')+field('loan_date','Pledge date','type="date" required value="'+today()+'"')+
      field('amount','Loan amount (INR)','type="number" min=".01" step=".01" required')+
      field('grams','Grams','type="number" min=".001" step=".001" required')+
      field('rate','Monthly interest %','type="number" min="0" step=".0001" required')+
      field('notes','Jewel details and notes','')+photo('photo','Jewel photo'),'Save pledge',async data=>{
        delete data.search;
        data.photo=await upload('jewel',data.photo);
        await result(db.from('loans').insert({...data,shop_id:shop}));
      });
    await searchCustomers(editor.elements.search,editor.elements.customer_id);
});
