import { mount,db,shop,result,customerPreview,customerPreviewFields,field,photo,today,form,upload,lookupField,searchCustomers,submitFinancial } from '../app.js';

mount('loans',async()=>{
    let uploadedFile;
    let photoPath;
    const editor=form(lookupField('customer_id','Customer','Type a name or mobile number')+
      field('bill','Bill number')+field('loan_date','Pledge date','type="date" required value="'+today()+'"')+
      field('amount','Loan amount (INR)','type="number" min=".01" step=".01" required')+
      field('grams','Grams','type="number" min=".001" step=".001" required')+
      field('rate','Monthly interest %','type="number" min="0" step=".0001" required')+
      field('notes','Jewel details and notes','')+photo('photo','Jewel photo'),'Save pledge',async (data,editor)=>{
        const file=editor.elements.photo.files[0];
        if(file!==uploadedFile){
          photoPath=await upload('jewel',file);
          uploadedFile=file;
        }
        data.photo=photoPath??null;
        await submitFinancial(editor,'pledge',data);
      });
    const preview=customerPreview(editor);
    const customer=editor.elements.customer_id;
    customer.onchange=()=>{
      const id=customer.value;
      return preview(id?async()=>({
        customer:await result(db.from('customers').select(customerPreviewFields).eq('shop_id',shop).eq('id',id).single())
      }):null);
    };
    searchCustomers(editor,'customer_id');
});
