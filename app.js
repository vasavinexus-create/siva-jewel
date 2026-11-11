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
  const controls='input:not([type=hidden]), select, textarea';
  target.querySelectorAll(controls).forEach(control=>control.setAttribute('enterkeyhint','next'));
  target.addEventListener('keydown',event=>{
    if(event.key!=='Enter'||event.defaultPrevented||event.isComposing||!event.target.matches(controls)) return;
    event.preventDefault();
    if(event.repeat) return;
    const fields=[...target.querySelectorAll(controls)];
    const next=fields.slice(fields.indexOf(event.target)+1).find(control=>!control.matches(':disabled')&&control.getClientRects().length);
    (next||target.querySelector('button[type=submit]:enabled'))?.focus();
  });
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

const customerPreviewFields='name,village,address,mobile,reference,photo';
function customerPreview(editor) {
  editor.insertAdjacentHTML('beforebegin','<section class="customer-preview" aria-label="Selected customer" hidden></section>');
  const panel=editor.previousElementSibling;
  let version=0;
  return run(async load=>{
    const ticket=++version;
    panel.replaceChildren();
    panel.hidden=true;
    if(!load) return;
    const {customer,jewel}=await load();
    if(ticket!==version||!customer) return;
    const content=document.createElement('div');
    content.className='preview-content';
    const details=[['Mobile',customer.mobile],['Village',customer.village],['Address',customer.address],['Reference',customer.reference]];
    content.innerHTML='<div><h2>'+escape(customer.name)+'</h2><dl>'+
      details.filter(([,value])=>value).map(([label,value])=>'<div><dt>'+label+'</dt><dd>'+escape(value)+'</dd></div>').join('')+
      '</dl></div><div class="preview-photos"></div>';
    const photos=content.querySelector('.preview-photos');
    const addPhoto=async (path,label)=>{
      if(!path) return;
      const figure=document.createElement('figure');
      figure.innerHTML='<figcaption>'+label+'</figcaption>';
      photos.append(figure);
      try {await showPhoto(figure,path,label);}
      catch {figure.insertAdjacentHTML('beforeend','<p>Photo unavailable.</p>');}
    };
    panel.append(content);
    panel.hidden=false;
    await Promise.all([addPhoto(customer.photo,'Customer photo'),addPhoto(jewel,'Pledged jewel')]);
  });
}

const lookupField=(name,label,placeholder)=>'<div class="lookup"><label for="'+name+'-search">'+label+'</label>'+
  '<input id="'+name+'-search" type="search" role="combobox" aria-autocomplete="list" aria-expanded="false" aria-controls="'+name+'-results" '+
  'placeholder="'+placeholder+'" autocomplete="off" required>'+
  '<input type="hidden" name="'+name+'"><div class="lookup-results" hidden>'+
  '<ul id="'+name+'-results" role="listbox" aria-label="'+label+' matches"></ul><p role="status" hidden></p></div></div>';

function searchLookup(editor,name,search,display) {
  const selected=editor.elements[name];
  const wrapper=selected.closest('.lookup');
  const input=wrapper.querySelector('[role=combobox]');
  const popup=wrapper.querySelector('.lookup-results');
  const list=popup.querySelector('[role=listbox]');
  const status=popup.querySelector('[role=status]');
  let matches=[];
  let active=-1;
  let version=0;
  let timer;
  const close=()=>{
    popup.hidden=true;
    input.setAttribute('aria-expanded','false');
    highlight(-1);
  };
  const open=message=>{
    popup.hidden=false;
    input.setAttribute('aria-expanded','true');
    status.textContent=message;
    status.hidden=!message;
  };
  function highlight(index) {
    list.children[active]?.setAttribute('aria-selected','false');
    active=index;
    const item=list.children[active];
    if(item){
      item.setAttribute('aria-selected','true');
      input.setAttribute('aria-activedescendant',item.id);
      item.scrollIntoView({block:'nearest'});
    } else input.removeAttribute('aria-activedescendant');
  }
  function setSelected(item) {
    const id=item?.id||'';
    input.setCustomValidity(id||!input.value?'':'Choose a result from the list.');
    if(selected.value===id) return;
    selected.value=id;
    selected.dispatchEvent(new Event('change'));
  }
  function choose(item) {
    input.value=display(item);
    setSelected(item);
    close();
    input.focus();
  }
  function schedule() {
    clearTimeout(timer);
    const ticket=++version;
    matches=[];
    highlight(-1);
    list.replaceChildren();
    const term=input.value.trim();
    if(!term){close();return;}
    open('Searching…');
    timer=setTimeout(async()=>{
      try {
        const found=await search(term);
        if(ticket!==version||document.activeElement!==input) return;
        matches=found;
        for(const [index,item] of matches.entries()){
          const entry=document.createElement('li');
          entry.id=list.id+'-'+index;
          entry.setAttribute('role','option');
          entry.setAttribute('aria-selected','false');
          entry.textContent=display(item);
          entry.addEventListener('pointerdown',event=>event.preventDefault());
          entry.addEventListener('click',()=>choose(item));
          list.append(entry);
        }
        const exact=matches.find(item=>item.exact_bill);
        if(exact) setSelected(exact);
        open(matches.length?'':'No matches found.');
      } catch(error) {
        if(ticket===version&&document.activeElement===input) open(error.message||'Search failed.');
      }
    },250);
  }
  input.oninput=()=>{
    setSelected(null);
    schedule();
  };
  input.onfocus=()=>{if(!selected.value) schedule();};
  input.onblur=()=>{clearTimeout(timer);version++;close();};
  input.addEventListener('keydown',event=>{
    if(event.isComposing) return;
    if(event.key==='Escape'&&!popup.hidden){
      event.preventDefault();
      clearTimeout(timer);
      version++;
      close();
    } else if((event.key==='ArrowDown'||event.key==='ArrowUp')&&matches.length&&!popup.hidden){
      event.preventDefault();
      highlight(event.key==='ArrowDown'?(active+1)%matches.length:(active<1?matches.length-1:active-1));
    } else if(event.key==='Enter'&&!popup.hidden){
      const match=matches[active]||(!selected.value&&matches.length===1?matches[0]:null);
      if(match) choose(match);
    }
  });
}
const searchCustomers=(editor,name)=>searchLookup(editor,name,
  term=>result(db.rpc('search_customers',{s:shop,term})),c=>c.name+' · '+c.mobile);

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

export {mount,db,shop,labels,permissions,escape,field,usernameField,photo,option,money,today,table,result,run,form,section,upload,showPhoto,customerPreview,customerPreviewFields,navigate,lookupField,searchCustomers,searchLookup,paginated,cursorList,fetchCursor,selectShop,submitFinancial};
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
    const activeShop=shops.find(item=>item.id===shop);
    const branding=activeShop?await result(db.from('shops').select('logo').eq('id',activeShop.id).maybeSingle()):null;
    const brandName=activeShop?.name || 'Siva Jewel';
    const brandMark=branding?.logo
      ? '<img class="brand-mark brand-logo" src="'+escape(branding.logo)+'" alt="">'
      : '<span class="brand-mark" aria-hidden="true">'+escape(brandName.trim().split(/\s+/).slice(0,2).map(word=>Array.from(word)[0]).join('').toUpperCase())+'</span>';
    const links=permitted.map(p=>'<a href="'+escape(pageUrl(p).href)+'"'+(p===page?' aria-current="page"':'')+'>'+escape(labelsByPage[p])+'</a>').join('');
    root.className=page==='login'?'auth-layout':'workspace-layout';
    root.innerHTML='<a class="skip-link" href="#main-content">Skip to content</a>'+
      '<header class="app-header">'+(links?'<details class="top-menu"><summary>Menu</summary><nav aria-label="Page menu">'+links+'</nav></details>':'')+
      '<div class="brand">'+brandMark+
      '<span class="brand-name">'+escape(brandName)+'<small>Pawn Ledger</small></span></div>'+
      (session?'<button id="logout" type="button">Sign out</button>':'')+'</header>'+
      '<main id="main-content" tabindex="-1"><h1>'+escape(labelsByPage[page])+'</h1><p id="message" role="status"></p></main>'+
      (links?'<div class="bottom-bar"><button type="button" data-scroll="-1" aria-label="Scroll menu left">‹</button>'+
        '<nav class="bottom-nav" aria-label="Main navigation">'+links+'</nav>'+
        '<button type="button" data-scroll="1" aria-label="Scroll menu right">›</button></div>':'');
    if(links){
      const menu=root.querySelector('.top-menu');
      menu.addEventListener('keydown',event=>{
        if(event.key==='Escape'&&menu.open){menu.open=false;menu.querySelector('summary').focus();}
      });
      root.addEventListener('click',event=>{if(!menu.contains(event.target)) menu.open=false;});
      const bar=root.querySelector('.bottom-nav');
      const active=bar.querySelector('[aria-current]');
      bar.scrollLeft=active.offsetLeft-(bar.clientWidth-active.offsetWidth)/2;
      root.querySelectorAll('[data-scroll]').forEach(button=>button.onclick=()=>{
        bar.scrollBy({left:Number(button.dataset.scroll)*bar.clientWidth*.75});
      });
    }
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
