import { usernamePattern } from './supabase/functions/_shared/login.js';
import { createClient } from '@supabase/supabase-js';
import './style.css';
import { Capacitor } from '@capacitor/core';
import { Camera, CameraResultType, CameraSource } from '@capacitor/camera';


const root = document.querySelector('#app');
const { VITE_SUPABASE_URL: url, VITE_SUPABASE_ANON_KEY: key } = import.meta.env;
const db = url && key ? createClient(url, key) : null;
const labels = {customers:'Customers',loans:'Pledge loan',release:'Release',reports:'Reports',accounting:'Accounting',audit:'Release audit',admin:'Staff & access'};
const permissions = Object.keys(labels).filter(page => page !== 'admin');
const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const field = (name, label, attributes = 'required') => '<label>'+label+'<input name="'+name+'" '+attributes+'></label>';
const usernameField = label => field('username',label,'required pattern="'+usernamePattern+'" autocomplete="username" autocapitalize="none" spellcheck="false" title="3 to 32 letters, digits, underscores or hyphens"');
const photo = (name, label) => '<div class="photo-field">'+
  field(name,label,'type="file" accept="image/jpeg,image/png,image/webp" capture="environment"')+
  (Capacitor.isNativePlatform()?'<button type="button" data-camera="'+name+'">Take '+label.toLowerCase()+'</button>':'')+'</div>';
const option = (value, label) => '<option value="'+escape(value)+'">'+escape(label)+'</option>';
const money = value => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR'}).format(value);
const today = () => new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const table = (headers,rows) => {
  if(!rows.length) return '<p class="empty-state">No records found.</p>';
  return '<div class="scroll"><table role="table"><thead role="rowgroup"><tr role="row">'+
    headers.map(h=>'<th scope="col" role="columnheader">'+escape(h)+'</th>').join('')+
    '</tr></thead><tbody role="rowgroup">'+rows.map(row=>'<tr role="row">'+row.map((value,index)=>
      '<td role="cell"><span class="cell-label" aria-hidden="true">'+escape(headers[index])+'</span><span>'+escape(value)+'</span></td>'
    ).join('')+'</tr>').join('')+'</tbody></table></div>';
};
let shop, shops;
const result = async request => {
  const {data,error} = await request;
  if(error) throw error;
  return data;
};

const run = fn => async event => {
  try { document.querySelector('#message').textContent = ''; await fn(event); }
  catch(error) { document.querySelector('#message').textContent = error.message; }
};
const form = (html, label, submit, refresh = true, container = document.querySelector('main')) => {
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
  container.append(target);
  target.onsubmit = run(async event => {
    event.preventDefault();
    const button = target.querySelector('button[type=submit]');
    button.disabled = true;
    try {
      await submit(Object.fromEntries(new FormData(target)),target);
      if(refresh) location.reload();
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

function searchInput(input, select, search, display, empty, onMatch = async () => {}) {
  let version=0;
  let timer;
  const load=async ticket=>{
    const matches=await search(input.value);
    if(ticket!==version) return;
    select.innerHTML=option('',empty)+matches.map(item=>option(item.id,display(item))).join('');
    const exact=matches.find(item=>item.exact_bill);
    if(exact) select.value=exact.id;
    await onMatch();
  };
  input.oninput=()=>{
    const ticket=++version;
    select.replaceChildren();
    clearTimeout(timer);
    timer=setTimeout(run(()=>load(ticket)),250);
  };
  return load(++version);
}
const searchCustomers = (input,select) => searchInput(input,select,
  term=>result(db.rpc('search_customers',{s:shop,term})),
  c=>c.name+' · '+c.mobile,'Select customer');

const pageSize=50;

function fetchCursor(query, columns, cursor) {
  for(const [name,ascending] of columns) query.order(name,{ascending});
  if(cursor){
    const literal=value=>'"'+String(value).replaceAll('\\','\\\\').replaceAll('"','\\"')+'"';
    const predicates=columns.map(([name,ascending],index)=>{
      const ties=columns.slice(0,index).map(([key])=>key+'.eq.'+literal(cursor[key]));
      const comparison=name+'.'+(ascending?'gt':'lt')+'.'+literal(cursor[name]);
      return ties.length?'and('+[...ties,comparison].join(',')+')':comparison;
    });
    const [name,ascending]=columns[0];
    query[ascending?'gte':'lte'](name,cursor[name]).or(predicates.join(','));
  }
  return result(query.limit(pageSize+1));
}

function cursorList(container, fetchPage, renderItems) {
  const cursors=[null];
  const load=async index=>{
    const items=await fetchPage(cursors[index]);
    const visible=items.slice(0,pageSize);
    container.replaceChildren();
    renderItems(visible,container);
    container.insertAdjacentHTML('beforeend','<p><button type="button" data-prev>Previous</button> <span>Page '+
      (index+1)+'</span> <button type="button" data-next>Next</button></p>');
    const prev=container.querySelector('[data-prev]');
    const next=container.querySelector('[data-next]');
    prev.disabled=index===0;
    next.disabled=items.length<=pageSize;
    const move=destination=>run(async()=>{
      prev.disabled=true;
      next.disabled=true;
      try {await load(destination);}
      finally {prev.disabled=index===0;next.disabled=items.length<=pageSize;}
    });
    prev.onclick=move(index-1);
    cursors[index+1]=visible.at(-1);
    next.onclick=move(index+1);
  };
  return load(0);
}
const paginated=(container,headers,fetchPage,mapRow)=>cursorList(container,fetchPage,(items,target)=>{
  target.innerHTML=table(headers,items.map(mapRow));
});

const financialRequests=new WeakMap();
function submitFinancial(form,operation,payload) {
  const serialized=JSON.stringify(payload);
  let request=financialRequests.get(form);
  if(request?.serialized!==serialized){
    request={serialized,id:crypto.randomUUID()};
    financialRequests.set(form,request);
  }
  return result(db.rpc('submit_financial',{s:shop,request_id:request.id,operation,payload}));
}

export {mount,db,shop,labels,permissions,escape,field,usernameField,photo,option,money,today,table,result,run,form,section,upload,showPhoto,navigate,searchCustomers,searchInput,paginated,cursorList,fetchCursor,selectShop,submitFinancial};
const pageUrl = page => new URL(page === 'login' ? './index.html' : './'+page+'.html', location.href);
const navigate = page => location.replace(pageUrl(page));
const shopKey = 'pawn-active-shop';
const selectShop=id=>{sessionStorage.setItem(shopKey,id);location.reload();};
const labelsByPage = {...labels, login:'Sign in', owner:'Platform owner', unassigned:'Shop access'};

async function mount(page, screen) {
  if(!db) {root.textContent='Set the Supabase URL and public key to connect the ledger.'; return;}
  try {
    const {session}=await result(db.auth.getSession());
    if(!session && page!=='login') return navigate('login');
    let permitted=[];
    if(session){
      const [owner,memberships]=await Promise.all([
        result(db.rpc('is_owner')),
        result(db.from('staff').select('shop_id,pages,shops(id,name,paused)').eq('user_id',session.user.id).order('shop_id'))
      ]);
      shops=memberships.flatMap(m=>m.shops&&!m.shops.paused?[m.shops]:[]);
      const selectedId=owner?sessionStorage.getItem(shopKey):null;
      if(owner){
        const query=db.from('shops').select('id,name,paused');
        const selected=selectedId?await result(query.eq('id',selectedId).maybeSingle()):null;
        const fallback=selected||shops[0]||await result(db.from('shops').select('id,name,paused').order('name').order('id').limit(1).maybeSingle());
        if(fallback&&!shops.some(s=>s.id===fallback.id)) shops.unshift(fallback);
      }
      shop=shops.find(s=>s.id===selectedId)?.id || shops[0]?.id;
      const allowed=memberships.find(m=>m.shop_id===shop && !shops.find(s=>s.id===shop)?.paused)?.pages || [];
      permitted=[...(owner?['owner']:[]),...Object.keys(labels).filter(p=>allowed.includes('admin')||allowed.includes(p))];
      if(page==='login'||(permitted.length?!permitted.includes(page):page!=='unassigned')) {
        return navigate(permitted[0]||'unassigned');
      }
    }
    root.className=page==='login'?'auth-layout':'workspace-layout';
    root.innerHTML='<a class="skip-link" href="#main-content">Skip to content</a>'+
      '<header class="app-header"><div class="brand"><span class="brand-mark" aria-hidden="true">SJ</span>'+
      '<span class="brand-name">Siva Jewel<small>Pawn Ledger</small></span></div>'+
      (session?'<button id="logout" type="button">Sign out</button>':'')+'</header>'+
      '<main id="main-content" tabindex="-1"><h1>'+escape(labelsByPage[page])+'</h1><p id="message" role="status"></p></main>'+
      (permitted.length?'<nav class="bottom-nav" aria-label="Main navigation">'+
        permitted.map(p=>'<a href="'+escape(pageUrl(p).href)+'"'+(p===page?' aria-current="page"':'')+'>'+escape(labelsByPage[p])+'</a>').join('')+
        '</nav>':'');
    if(session) document.querySelector('#logout').onclick=run(async()=>{
      await result(db.auth.signOut());
      sessionStorage.removeItem(shopKey);
      navigate('login');
    });
    await screen();
  } catch(error) {
    const message=document.querySelector('#message')||root;
    message.textContent=error.message;
  }
}
