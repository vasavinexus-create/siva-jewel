import { dateField,db,escape,field,form,money,result,shop } from '../app.js';
import { loadBankLedgers,paymentFields } from '../accounting.js';

export function mountReleaseEdit(panel) {
  const details=document.createElement('div');
  form(field('bill','Released bill number','required'),'Find release',async ({bill})=>{
    details.replaceChildren();
    const loan=await result(db.from('loans').select('id,bill,loan_date')
      .eq('shop_id',shop).eq('bill',bill.trim()).maybeSingle());
    if(!loan) throw new Error('Released bill not found.');
    const release=await result(db.from('releases').select('*')
      .eq('shop_id',shop).eq('loan_id',loan.id).maybeSingle());
    if(!release) throw new Error('Released bill not found.');

    const heading=document.createElement('h2');
    heading.textContent=loan.bill;
    details.append(heading);
    const editor=form(dateField('release_date','Release date',release.release_date)+
      field('months','Months charged','type="number" min="0" step="1" required value="'+escape(release.months)+'"')+
      field('rate','Monthly interest %','type="number" min="0" max="9999.9999" step=".0001" required value="'+escape(release.rate)+'"')+
      field('received_amount','Received amount (INR)','type="number" min="0" step=".01" required value="'+escape(release.total)+'"')+
      '<p>Previously calculated amount '+money(release.calculated_total??release.total)+'</p>'+
      '<label>Short payment reason, if applicable<textarea name="short_payment_reason">'+escape(release.short_payment_reason??'')+'</textarea></label>'+
      '<label><input type="checkbox" name="full_principal" '+(release.full_principal?'checked':'')+'> Charge interest on the full principal from the pledge date</label>'+
      '<label><input type="checkbox" name="partial_interest_only" '+(release.partial_interest_only?'checked':'')+'> Treat all partial payments as advance interest</label>'+
      paymentFields+
      '<label>Reason for correction<textarea name="reason" required></textarea></label>',
      'Save correction',async (data,editor)=>{
        data.full_principal=editor.elements.full_principal.checked;
        data.partial_interest_only=editor.elements.partial_interest_only.checked;
        await result(db.rpc('edit_release',{s:shop,loan:loan.id,expected:release,details:data}));
        details.textContent='Release correction saved.';
      },false,details);
    editor.elements.release_date.min=loan.loan_date;
    const save=editor.querySelector('button[type=submit]');
    save.disabled=true;
    await loadBankLedgers(editor);
    if(release.payment_ledger_id){
      editor.elements.payment_mode.value='bank';
      editor.elements.payment_mode.onchange();
      editor.elements.payment_ledger_id.value=release.payment_ledger_id;
    }
    save.disabled=false;
  },false,panel);
  panel.append(details);
}
