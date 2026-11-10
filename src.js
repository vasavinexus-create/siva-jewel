import { createClient } from '@supabase/supabase-js';
import './style.css';
import { Capacitor } from '@capacitor/core';
import { Camera, CameraResultType, CameraSource } from '@capacitor/camera';
import { accounts, ledger, balances } from './accounting.js';

const root = document.querySelector('#app');
const { VITE_SUPABASE_URL: url, VITE_SUPABASE_ANON_KEY: key } = import.meta.env;
const db = url && key ? createClient(url, key) : null;
const labels = {customers:'Customers',loans:'Pledge loan',release:'Release',reports:'Reports',accounting:'Accounting',audit:'Release audit',admin:'Staff & access'};
const permissions = Object.keys(labels).filter(page => page !== 'admin');
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const field = (name, label, attributes = 'required') => '<label>'+label+'<input name="'+name+'" '+attributes+'></label>';
const photo = (name, label) => field(name,label,'type="file" accept="image/jpeg,image/png,image/webp" capture="environment"') +
  (Capacitor.isNativePlatform() ? '<button type="button" data-camera="'+name+'">Take '+label.toLowerCase()+'</button>' : '');
const option = (value, label) => '<option value="'+escape(value)+'">'+escape(label)+'</option>';
const money = value => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR'}).format(value);
const today = () => new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const table = (headers,rows) => '<div class="scroll"><table><thead><tr>'+headers.map(h=>'<th>'+escape(h)+'</th>').join('')+'</tr></thead><tbody>'+rows.map(row=>'<tr>'+row.map(v=>'<td>'+escape(v)+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>';
let shop, page, owner, shops, allowed;
const result = async request => {
  const {data,error} = await request;
  if(error) throw error;
  return data;
};
const rows = async (name, column = 'id', ascending = true) => {
  const all = [];
  for (let start = 0; ; start += 500) {
    const query=db.from(name).select('*').eq('shop_id',shop).order(column,{ascending});
    if(['name','entry_date'].includes(column)) query.order('id');
    const batch = await result(query.range(start,start+499));
    all.push(...batch);
    if(batch.length < 500) return all;
  }
};
const run = fn => async event => {
  try { document.querySelector('#message').textContent = ''; await fn(event); }
  catch(error) { document.querySelector('#message').textContent = error.message; }
};
const form = (html, label, submit, refresh = true) => {
  const target = document.createElement('form');
  target.innerHTML = html+'<button type="submit">'+label+'</button>';
  target.querySelectorAll('[data-camera]').forEach(button=>button.onclick=run(async()=>{
    const image=await Camera.getPhoto({source:CameraSource.Camera,resultType:CameraResultType.Uri,quality:85});
    const imageResponse=await fetch(image.webPath);
    if(!imageResponse.ok) throw new Error('Could not read the captured photo.');
    const blob=await imageResponse.blob();
    const files=new DataTransfer();
    files.items.add(new File([blob],'capture.jpg',{type:'image/jpeg'}));
    target.elements[button.dataset.camera].files=files.files;
  }));
  document.querySelector('main').append(target);
  target.onsubmit = run(async event => {
    event.preventDefault();
    const button = target.querySelector('button[type=submit]');
    button.disabled = true;
    try {
      await submit(Object.fromEntries(new FormData(target)),target);
      if(refresh) await render();
    } finally {button.disabled = false;}
  });
  return target;
};
const section = html => document.querySelector('main').insertAdjacentHTML('beforeend','<section>'+html+'</section>');
const upload = async (category,file) => {
  if (!file?.size) return null;
  const path = shop+'/'+category+'/'+crypto.randomUUID();
  await result(db.storage.from('pawn-media').upload(path,file));
  return path;
};
const showPhoto = async (container,path,label) => {
  if(!path) return;
  const {signedUrl} = await result(db.storage.from('pawn-media').createSignedUrl(path,60));
  const img = document.createElement('img');
  img.src=signedUrl;
  img.alt=label;
  container.append(img);
};
async function start() {
  const {session} = await result(db.auth.getSession());
  if(!session) { page='login'; return render(); }
  owner = await result(db.rpc('is_owner'));
  shops = await result(db.from('shops').select('*').order('name'));
  const memberships = await result(db.from('staff').select('*').eq('user_id',session.user.id));
  shop = shops.find(s=>s.id===shop)?.id || shops[0]?.id;
  allowed = memberships.find(m=>m.shop_id===shop)?.pages || [];
  if(allowed.includes('admin')) allowed=Object.keys(labels);
  const pages = [...(owner?['owner']:[]),...Object.keys(labels).filter(p=>allowed.includes(p))];
  if(!pages.includes(page)) page=pages[0] || 'unassigned';
  await render(pages);
}
async function render(pages = [...(owner?['owner']:[]),...Object.keys(labels).filter(p=>allowed?.includes(p))]) {
  root.innerHTML = '<header><strong>Siva Jewel · Pawn Ledger</strong>'+
    (page==='login'?'':(shops.length?'<select id="shop" aria-label="Shop">'+shops.map(s=>option(s.id,s.name)).join('')+'</select>':'')+'<button id="logout">Sign out</button>')+
    '</header>'+(page==='login'?'':'<nav>'+pages.map(p=>'<button data-page="'+p+'" '+(page===p?'aria-current="page"':'')+'>'+ (labels[p] || 'Platform owner')+'</button>').join('')+'</nav>')+
    '<main><h1>'+escape(labels[page] || {login:'Sign in',owner:'Platform owner',unassigned:'Shop access'}[page])+'</h1><p id="message" role="status"></p></main>';
  if(page==='login'){
    form(field('email','Email','type="email" required')+field('password','Password','type="password" required'),'Sign in',async data=>{
      await result(db.auth.signInWithPassword(data)); await start();
    },false);
    return;
  }
  document.querySelector('#logout').onclick = run(async()=>{await result(db.auth.signOut()); shop=null; await start();});
  const selector=document.querySelector('#shop');
  if(selector){selector.value=shop; selector.onchange=run(async()=>{shop=selector.value; await start();});}
  document.querySelectorAll('[data-page]').forEach(button=>button.onclick=run(async()=>{page=button.dataset.page; await render();}));
  await screens[page]();
}
const screens = {
  unassigned(){section('Your account needs access to an active shop.');},
  async owner(){
    form(field('name','Shop name'),'Add shop',async data=>{await result(db.from('shops').insert(data)); await start();},false);
    for(const item of shops){
      form('<strong>'+escape(item.name)+'</strong>',item.paused?'Resume shop':'Pause shop',async()=>{
        await result(db.from('shops').update({paused:!item.paused}).eq('id',item.id)); await start();
      },false);
    }
    if(shop) form(field('email','Shop admin email','type="email" required')+field('password','Temporary password','type="password" minlength="12" required'),
      'Create shop admin',data=>result(db.functions.invoke('create-staff',{body:{...data,shop,admin:true}})));
  },
  async admin(){
    const staff=await rows('staff','user_id');
    const checks = selected => permissions.map(p=>'<label><span><input name="'+p+'" type="checkbox" '+(selected.includes(p)?'checked':'')+'> '+escape(labels[p]||'Shop sign-in')+'</span></label>').join('');
    const selected = data => permissions.filter(p=>data[p]);
    form(field('email','Staff email','type="email" required')+field('password','Temporary password','type="password" minlength="12" required')+checks([]),
      'Create staff',data=>result(db.functions.invoke('create-staff',{body:{email:data.email,password:data.password,shop,pages:selected(data)}})));
    for(const member of staff.filter(m=>!m.pages.includes('admin'))){
      form('<strong>'+escape(member.email || member.user_id)+'</strong>'+checks(member.pages),'Save access',data=>result(db.from('staff').update({pages:selected(data)}).eq('shop_id',shop).eq('user_id',member.user_id)));
    }
  },
  async customers(){
    const customers=await rows('customers','name');
    form(field('name','Name')+field('village','Village','')+field('address','Address','')+field('mobile','Mobile','type="tel" required')+
      field('reference','Reference','')+photo('photo','Customer photo')+photo('aadhaar_photo','Aadhaar photo'),'Add customer',async data=>{
      data.photo=await upload('customer',data.photo);
      data.aadhaar_photo=await upload('identity',data.aadhaar_photo);
      await result(db.from('customers').insert({...data,shop_id:shop}));
    });
    const select=form('<label>Customer history<select name="customer">'+customers.map(c=>option(c.id,c.name+' · '+c.mobile)).join('')+'</select></label>',
      'Show history',async data=>{
        const customer=customers.find(c=>c.id===data.customer);
        if(!customer) return;
        const [loans,releases]=await Promise.all([rows('loans'),rows('releases','loan_id')]);
        const detail=document.querySelector('#history');
        detail.innerHTML='<h2>'+escape(customer.name)+'</h2><p>'+[customer.mobile,customer.address,customer.village,customer.reference].map(escape).join(' · ')+'</p>'+
          table(['Bill','Pledged','Principal','Released','Interest','Total'],loans.filter(l=>l.customer_id===customer.id).map(l=>{
            const r=releases.find(item=>item.loan_id===l.id);
            return [l.bill,l.loan_date,money(l.amount),r?.release_date,r&&money(r.interest),r&&money(r.total)];
          }));
        await Promise.all([showPhoto(detail,customer.photo,'Customer photo'),showPhoto(detail,customer.aadhaar_photo,'Aadhaar photo')]);
      },false);
    select.insertAdjacentHTML('afterend','<section id="history"></section>');
  },
  async loans(){
    const customers=await rows('customers','name');
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
    const filter=()=>{editor.elements.customer_id.innerHTML=option('','Select customer')+
      customers.filter(c=>(c.name+' '+c.mobile).toLowerCase().includes(editor.elements.search.value.trim().toLowerCase()))
        .map(c=>option(c.id,c.name+' · '+c.mobile)).join('');};
    editor.elements.search.oninput=filter; filter();
  },
  async release(){
    const [loans,customers,releases]=await Promise.all([rows('loans'),rows('customers'),rows('releases','loan_id')]);
    const closed=new Set(releases.map(r=>r.loan_id));
    const editor=form(field('search','Bill, customer name or mobile','type="search"')+'<label>Bill<select name="loan" required></select></label>'+
      field('on_date','Release date','type="date" required value="'+today()+'"')+
      field('billed_months','Months charged','type="number" min="0" step="1" required')+
      field('monthly_rate','Monthly interest %','type="number" min="0" step=".0001" required'),'Record release',async data=>{
        delete data.search;
        await result(db.rpc('record_release',{...data,billed_months:Number(data.billed_months),monthly_rate:Number(data.monthly_rate)}));
      });
    section('<div id="quote"></div><div id="jewel"></div>');
    const e=editor.elements;
    const current=()=>loans.find(l=>l.id===e.loan.value);
    const quote=()=>{const l=current(), target=document.querySelector('#quote');
      if(!l){target.textContent='Select an open bill.'; return;}
      const interest=Math.round((l.amount*e.monthly_rate.value*e.billed_months.value)+1e-8)/100;
      target.innerHTML='<h2>'+escape(l.bill)+'</h2><p>'+escape(l.loan_date)+' · '+escape(l.grams)+' g · '+escape(l.notes)+'</p>'+
        '<div class="metrics"><span>Loan '+money(l.amount)+'</span><span>Interest '+money(interest)+'</span><strong>Total '+money(Number(l.amount)+interest)+'</strong></div>';
    };
    const defaults=()=>{const l=current(); if(l){e.billed_months.value=months(l.loan_date,e.on_date.value);e.monthly_rate.value=l.rate;e.on_date.min=l.loan_date;} quote();};
    const load=run(async()=>{defaults();const target=document.querySelector('#jewel');target.replaceChildren();await showPhoto(target,current()?.photo,'Pledged jewel');});
    const search=()=>{const query=e.search.value.toLowerCase().trim();const matches=loans.filter(l=>{
      const c=customers.find(c=>c.id===l.customer_id);
      return !closed.has(l.id)&&(l.bill.toLowerCase().includes(query)|| (c?.name+' '+c?.mobile).toLowerCase().includes(query));
    });
    e.loan.innerHTML=option('','Select bill')+matches.map(l=>option(l.id,l.bill+' · '+(customers.find(c=>c.id===l.customer_id)?.name||''))).join('');
    const exact=matches.find(l=>l.bill.toLowerCase()===query);
    if(exact)e.loan.value=exact.id;
    return load();};
    e.search.oninput=search;e.loan.onchange=load;e.on_date.onchange=defaults;e.monthly_rate.oninput=quote;e.billed_months.oninput=quote;
    await search();
  },
  async audit(){
    const [loans,releases]=await Promise.all([rows('loans'),rows('releases','loan_id')]);
    const pending=releases.filter(r=>!r.reviewed_at&&(r.rate!==r.original_rate||r.months!==r.original_months));
    if(!pending.length) section('No release overrides awaiting review.');
    for(const r of pending){
      form('<strong>'+escape(loans.find(l=>l.id===r.loan_id)?.bill)+'</strong><span>'+escape(r.release_date)+'</span>'+
        '<span>Months '+r.original_months+' → '+r.months+'</span><span>Monthly rate '+r.original_rate+'% → '+r.rate+'%</span>',
        'Submit review',()=>result(db.rpc('review_release',{loan:r.loan_id})));
    }
  },
  async accounting(){
    const options=option('','Select account')+accounts.map(a=>option(a,a)).join('');
    form(field('entry_date','Posting date','type="date" required value="'+today()+'"')+
      field('description','Description')+'<label>Debit<select name="debit" required>'+options+'</select></label>'+
      '<label>Credit<select name="credit" required>'+options+'</select></label>'+
      field('amount','Amount (INR)','type="number" min=".01" step=".01" required'),
      'Post journal entry',data=>result(db.from('journal').insert({...data,shop_id:shop})));
    const journal=await rows('journal','entry_date',false);
    section(table(['Date','Description','Debit','Credit','Amount'],journal.map(j=>[j.entry_date,j.description,j.debit,j.credit,money(j.amount)])));
  },
  async reports(){
    const [loans,releases,journal]=await Promise.all([rows('loans'),rows('releases','loan_id'),rows('journal')]);
    const entries=ledger(loans,releases,journal);
    form('<label>Report<select name="kind">'+['Day book','Pledging','Releases','Profit and loss','Balance sheet','Trial balance','General ledger','Loan balance'].map(v=>option(v,v)).join('')+'</select></label>'+
      field('from','From','type="date"')+field('to','Through','type="date" value="'+today()+'"'),'Run report',data=>{
        const {kind,from,to}=data;
        const within=d=>(!from||d>=from)&&(!to||d<=to);
        const loanById=new Map(loans.map(l=>[l.id,l]));
        const pledges=loans.filter(l=>within(l.loan_date));
        const receipts=releases.filter(r=>within(r.release_date));
        let content;
        if(kind==='Loan balance'){
          const repaid=new Set(releases.filter(r=>!to||r.release_date<=to).map(r=>r.loan_id));
          const open=loans.filter(l=>(!to||l.loan_date<=to)&&!repaid.has(l.id));
          content='<p>Outstanding principal '+money(open.reduce((sum,l)=>sum+Number(l.amount),0))+'</p>'+
            table(['Bill','Date','Principal'],open.map(l=>[l.bill,l.loan_date,money(l.amount)]));
        } else if(kind==='Profit and loss'){
          const b=balances(entries.filter(e=>within(e.entry_date)));
          content=table(['Account','Amount'],[
            ['Interest income',-b['Interest income']],['Other income',-b['Other income']],['Expenses',b.Expenses],
            ['Net profit',-b['Interest income']-b['Other income']-b.Expenses]
          ].map(([a,n])=>[a,money(n)]));
        } else if(kind==='Balance sheet'){
          const b=balances(entries.filter(e=>!to||e.entry_date<=to));
          content=table(['Account','Amount'],[
            ['Cash',b.Cash],['Pawn loans',b['Pawn loans']],['Other assets',b['Other assets']],
            ['Total assets',b.Cash+b['Pawn loans']+b['Other assets']],
            ['Liabilities',-b.Liabilities],['Capital',-b.Capital],
            ['Accumulated earnings',-b['Interest income']-b['Other income']-b.Expenses],
            ['Total liabilities and equity',-b.Liabilities-b.Capital-b['Interest income']-b['Other income']-b.Expenses]
          ].map(([a,n])=>[a,money(n)]));
        } else if(kind==='Trial balance'){
          const b=balances(entries.filter(e=>!to||e.entry_date<=to));
          content=table(['Account','Debit balance','Credit balance'],Object.entries(b).map(([a,n])=>[a,money(Math.max(0,n)),money(Math.max(0,-n))]));
        } else if(kind==='General ledger' || kind==='Day book'){
          const period=entries.filter(e=>within(e.entry_date));
          content=table(['Date','Entry','Debit','Credit','Amount'],period.map(e=>[e.entry_date,e.description,e.debit,e.credit,money(e.amount)]));
        } else {
          const entries=[
            ...(kind==='Releases'?[]:pledges.map(l=>[l.loan_date,l.bill,'Pledge',0,l.amount,0])),
            ...(kind==='Pledging'?[]:receipts.map(r=>[r.release_date,loanById.get(r.loan_id)?.bill,'Release',r.total,0,r.interest]))
          ].sort((a,b)=>a[0].localeCompare(b[0]));
          content=table(['Date','Bill','Type','Cash in','Cash out','Interest'],entries.map(r=>[...r.slice(0,3),...r.slice(3).map(money)]));
        }
        document.querySelector('#report').innerHTML='<h2>'+escape(kind)+'</h2>'+content;
      },false).insertAdjacentHTML('afterend','<section id="report"></section>');
  }
};
function months(start,end){
  if(!end||end<=start)return 0;
  const [y,m,d]=start.split('-').map(Number), [ey,em]=end.split('-').map(Number);
  const count=(ey-y)*12+em-m;
  const day=Math.min(d,new Date(Date.UTC(ey,em,0)).getUTCDate());
  const anniversary=end.slice(0,7)+'-'+String(day).padStart(2,'0');
  return count+Number(end>anniversary);
}
if(db) start().catch(error=>{root.textContent=error.message;});
else root.textContent='Set VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY to connect the ledger.';
if(import.meta.env.PROD && 'serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(console.warn);
