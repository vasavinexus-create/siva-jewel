export const accounts = ['Cash','Other assets','Liabilities','Capital','Other income','Expenses'];

export function ledger(loans,releases,journal) {
  const loanById = new Map(loans.map(l=>[l.id,l]));
  return [
    ...loans.map(l=>({entry_date:l.loan_date,description:'Pledge '+l.bill,debit:'Pawn loans',credit:'Cash',amount:l.amount})),
    ...releases.flatMap(r=>{
      const loan=loanById.get(r.loan_id);
      const description='Release '+loan.bill;
      const entry_date=r.release_date;
      return [
        {entry_date,description,debit:'Cash',credit:'Pawn loans',amount:loan.amount},
        ...(Number(r.interest)?[{entry_date,description,debit:'Cash',credit:'Interest income',amount:r.interest}]:[])
      ];
    }),
    ...journal
  ].sort((a,b)=>a.entry_date.localeCompare(b.entry_date));
}

export function balances(entries) {
  const totals = new Map([...accounts,'Pawn loans','Interest income'].map(account=>[account,0]));
  for (const {debit,credit,amount} of entries) {
    const cents=Math.round(Number(amount)*100);
    totals.set(debit,totals.get(debit)+cents);
    totals.set(credit,totals.get(credit)-cents);
  }
  return Object.fromEntries([...totals].map(([account,cents])=>[account,cents/100]));
}
