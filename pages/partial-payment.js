import { dateField, db,shop,field,money,today,result,run,form,loanPreview,lookupField,searchLookup,submitFinancial } from '../app.js';
import { paymentFields,loadBankLedgers } from '../accounting.js';

export async function mountPartialPayment(panel) {
  const partial=form(lookupField('partial_loan','Bill','Type a bill number, customer name or mobile')+
    '<div aria-live="polite">'+
      '<h2>Current loan balance</h2>'+
      '<div class="metrics"><span>Current principal <strong data-principal>—</strong></span>'+
      '<span>Current interest due <strong data-interest>—</strong></span></div>'+
      '<p data-balances>Select an open bill.</p>'+
    '</div>'+
    dateField('paid_on','Payment date')+
    field('interest_advance','Interest advance (INR)','type="number" min="0" step=".01"')+
    field('principal_paid','Paid toward principal (INR)','type="number" min="0" step=".01"')+
    '<p>Any payment above the outstanding principal is recorded as advance interest.</p>'+
    paymentFields,'Save partial payment',async (data,editor)=>{
    if(!partialReady) throw new Error('Select a bill and wait for its current balances.');
    const {partial_loan,...payment}=data;
    payment.interest_advance ||= '0';
    payment.principal_paid ||= '0';
    if(Number(payment.interest_advance)+Number(payment.principal_paid)<=0) {
      throw new Error('Enter an interest amount, a principal amount, or both.');
    }
    const enteredPrincipal=Number(payment.principal_paid);
    const todayPayment=payment.paid_on===today();
    const principalPaid=todayPayment?Math.min(enteredPrincipal,currentPrincipal):enteredPrincipal;
    const advance=Number(payment.interest_advance)+enteredPrincipal-principalPaid;
    const allocation=todayPayment
      ? 'Principal '+money(principalPaid)+'\nAdvance interest '+money(advance)
      : 'Principal entered '+money(enteredPrincipal)+'\nAdvance interest entered '+money(advance)+
        '\nThe saved split uses the principal outstanding on the payment date.';
    if(!window.confirm('Record payment for '+partial.querySelector('[role=combobox]').value+'?\n'+allocation)) return;
    await submitFinancial(editor,'partial_payment',{...payment,loan:partial_loan});
    location.reload();
  },false,panel);
  const preview=loanPreview(partial);
  let partialReady=false;
  let currentPrincipal=0;
  let partialVersion=0;
  const balances=partial.querySelector('[data-balances]');
  const principal=partial.querySelector('[data-principal]');
  const interest=partial.querySelector('[data-interest]');
  const partialButton=partial.querySelector('button[type=submit]');
  partialButton.disabled=true;
  partial.elements.partial_loan.onchange=run(async()=>{
    const ticket=++partialVersion;
    const loan=partial.elements.partial_loan.value;
    void preview(loan);
    partialReady=false;
    partialButton.disabled=true;
    principal.textContent=interest.textContent='—';
    partial.elements.paid_on.removeAttribute('min');
    balances.textContent=loan?'Loading current balances…':'Select an open bill.';
    if(!loan) return;
    try {
      const q=await result(db.rpc('release_quote',{loan,on_date:today(),billed_months:null,monthly_rate:null,full_principal:false}));
      if(ticket!==partialVersion) return;
      partial.elements.paid_on.min=q.loan_date;
      currentPrincipal=Number(q.amount)+Number(q.advance_to_principal??0);
      principal.textContent=money(currentPrincipal);
      interest.textContent=money(q.interest);
      balances.textContent='';
      partialReady=true;
      partialButton.disabled=false;
    } catch(error) {
      if(ticket!==partialVersion) return;
      balances.textContent='Could not load current balances.';
      throw error;
    }
  });
  const findBills=term=>result(db.rpc('search_open_loans',{s:shop,term}));
  const billLabel=l=>l.bill+' · '+l.customer;
  searchLookup(partial,'partial_loan',findBills,billLabel);
  await loadBankLedgers(partial);
}
