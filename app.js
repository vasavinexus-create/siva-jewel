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
const photo = (name, label) => field(name,label,'type="file" accept="image/jpeg,image/png,image/webp" capture="environment"') +
  (Capacitor.isNativePlatform() ? '<button type="button" data-camera="'+name+'">Take '+label.toLowerCase()+'</button>' : '');
const option = (value, label) => '<option value="'+escape(value)+'">'+escape(label)+'</option>';
const money = value => new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR'}).format(value);
const today = () => new Intl.DateTimeFormat('en-CA',{timeZone:'Asia/Kolkata',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
const table = (headers,rows) => '<div class="scroll"><table><thead><tr>'+headers.map(h=>'<th>'+escape(h)+'</th>').join('')+'</tr></thead><tbody>'+rows.map(row=>'<tr>'+row.map(v=>'<td>'+escape(v)+'</td>').join('')+'</tr>').join('')+'</tbody></table></div>';
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

function paginated(container, headers, fetchPage, mapRow) {
  const size=50;
  let offset=0;
  const load=async()=>{
    const items=await fetchPage(offset,offset+size);
    container.innerHTML=table(headers,items.slice(0,size).map(mapRow))+
      '<p><button type="button" data-prev>Previous</button> <span>Page '+(offset/size+1)+'</span> <button type="button" data-next>Next</button></p>';
    const prev=container.querySelector('[data-prev]');
    const next=container.querySelector('[data-next]');
    prev.disabled=offset===0;
    next.disabled=items.length<=size;
    const move=delta=>run(async()=>{
      prev.disabled=true;
      next.disabled=true;
      const old=offset;
      offset+=delta;
      try {await load();}
      catch(error){offset=old;prev.disabled=offset===0;next.disabled=items.length<=size;throw error;}
    });
    prev.onclick=move(-size);
    next.onclick=move(size);
  };
  return load();
}

function pageOffset() {
  const page=Number(new URLSearchParams(location.search).get('page'));
  return Number.isSafeInteger(page)&&page>1&&page<100000 ? (page-1)*50 : 0;
}
function pageLinks(offset,more) {
  const page=offset/50+1;
  if(page===1&&!more) return;
  section((page>1?'<a href="?page='+(page-1)+'">Previous</a> ':'')+
    'Page '+page+(more?' <a href="?page='+(page+1)+'">Next</a>':''));
}

export {mount,db,shop,shops,labels,permissions,escape,field,usernameField,photo,option,money,today,table,result,run,form,section,upload,showPhoto,navigate,searchCustomers,searchInput,paginated,pageOffset,pageLinks};
const pageUrl = page => new URL(page === 'login' ? './index.html' : './'+page+'.html', location.href);
const navigate = page => location.replace(pageUrl(page));
const shopKey = 'pawn-active-shop';
const labelsByPage = {...labels, login:'Sign in', owner:'Platform owner', unassigned:'Shop access'};

async function mount(page, screen) {
  if(!db) {root.textContent='Set the Supabase URL and public key to connect the ledger.'; return;}
  try {
    const {session}=await result(db.auth.getSession());
    if(!session && page!=='login') return navigate('login');
    let permitted=[];
    if(session){
      const [owner, visibleShops, memberships]=await Promise.all([
        result(db.rpc('is_owner')),
        result(db.from('shops').select('id,name,paused').order('name')),
        result(db.from('staff').select('shop_id,pages').eq('user_id',session.user.id))
      ]);
      shops=visibleShops;
      shop=shops.find(s=>s.id===sessionStorage.getItem(shopKey))?.id || shops[0]?.id;
      const allowed=memberships.find(m=>m.shop_id===shop && !shops.find(s=>s.id===shop)?.paused)?.pages || [];
      permitted=[...(owner?['owner']:[]),...Object.keys(labels).filter(p=>allowed.includes('admin')||allowed.includes(p))];
      if(page==='login'||(permitted.length?!permitted.includes(page):page!=='unassigned')) {
        return navigate(permitted[0]||'unassigned');
      }
    }
    root.innerHTML='<header><strong>Siva Jewel · Pawn Ledger</strong>'+
      (session?(shops.length?'<select id="shop" aria-label="Shop">'+shops.map(s=>option(s.id,s.name)).join('')+'</select>':'')+
        '<button id="logout">Sign out</button>':'')+'</header>'+
      (permitted.length?'<nav>'+permitted.map(p=>'<a href="'+escape(pageUrl(p).href)+'"'+(p===page?' aria-current="page"':'')+'>'+escape(labelsByPage[p])+'</a>').join('')+'</nav>':'')+
      '<main><h1>'+escape(labelsByPage[page])+'</h1><p id="message" role="status"></p></main>';
    if(session) document.querySelector('#logout').onclick=run(async()=>{
      await result(db.auth.signOut());
      sessionStorage.removeItem(shopKey);
      navigate('login');
    });
    const selector=document.querySelector('#shop');
    if(selector){
      selector.value=shop;
      selector.onchange=()=>{sessionStorage.setItem(shopKey,selector.value);location.reload();};
    }
    await screen();
  } catch(error) {
    const message=document.querySelector('#message')||root;
    message.textContent=error.message;
  }
}
